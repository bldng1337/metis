import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

Map<String, dynamic> _recompute(Map<String, dynamic> row) {
  final data = (row['episodedata'] as Map?) ?? const {};
  return {
    ...row,
    'sort_read': data.values.where((e) => e['finished'] == true).length,
  };
}

const _schema = FieldCrdt(
  groups: {
    'source': ['entry', 'original', 'lastRefreshed'],
  },
  passive: {'source'},
  lww: {'userRating': null, 'note': null, 'episode': 0},
  maps: {
    'episodedata': FieldMap(
      fields: {
        'bookmark': false,
        'finished': false,
        'progress': null,
        'note': null,
      },
      sets: {'quotes'},
    ),
  },
  sets: {'categories'},
  derived: {'sort_read'},
  recompute: _recompute,
);

const _entry = DBTable('entry');
const _id = DBRecord('entry', 'e1');
const _tables = {
  SyncTable(
      table: _entry,
      version: 1,
      range: VersionRange.exact(1),
      fields: _schema),
};

typedef _Node = ({AdapterSurrealDB db, CrdtAdapter crdt});

Future<_Node> _newDb({Set<SyncTable> tables = _tables}) async {
  final db = await AdapterSurrealDB.connect('mem://');
  await db.use(ns: 'fields', db: 'fields');
  final crdt = await db.setCrdtAdapter(tablesToSync: tables);
  return (db: db, crdt: crdt);
}

Map<String, dynamic> _row({
  String source = 'v1',
  Map<String, dynamic>? eps,
  String? note,
  double? rating,
  List<Object> categories = const [],
  int read = 0,
}) =>
    {
      'entry': {'title': source},
      'original': {'title': source},
      'lastRefreshed': source,
      'episodedata': eps ?? <String, dynamic>{},
      'note': note,
      'userRating': rating,
      'episode': 0,
      'categories': categories,
      'sort_read': read,
    };

Map<String, dynamic> _ep(
        {bool bookmark = false,
        bool finished = false,
        String? progress,
        String? note,
        List<Object> quotes = const []}) =>
    {
      'bookmark': bookmark,
      'finished': finished,
      'progress': progress,
      'note': note,
      'quotes': quotes,
    };

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 5));

Future<Map<String, dynamic>> _read(_Node n, [DBRecord id = _id]) async {
  final row = await n.db.select(id);
  return Map<String, dynamic>.from(row as Map)..remove('id');
}

/// Two devices that share [row], then go offline.
Future<(_Node, _Node)> _pair(Map<String, dynamic> row) async {
  final a = await _newDb();
  final b = await _newDb();
  await a.db.upsert(_id, row);
  await _tick();
  await a.crdt.sync(b.crdt.syncRepo);
  await _tick();
  return (a, b);
}

class _EntryData with DBConstClass, DBModifiableClass, DBLiveClass {
  final String key;
  Map<String, dynamic> row;

  _EntryData(this.key, this.row);

  static _EntryData fromJson(Map<String, dynamic> json) => _EntryData(
      (json['id'] as DBRecord).id as String,
      Map<String, dynamic>.from(json)..remove('id'));

  @override
  DBRecord get dbId => DBRecord('entry', key);

  @override
  Map<String, dynamic> toDBJson() => row;

  @override
  void onDBChange(DBChange change) {
    if (change.state != null) row = change.state!;
  }
}

void dotest() {
  group('merging across devices', () {
    test('offline reading on two devices keeps everything', () async {
      final (a, b) = await _pair(_row());

      await a.db.upsert(
          _id,
          _row(eps: {
            'ep1': _ep(finished: true),
            'ep3': _ep(bookmark: true),
          }));
      await _tick();
      await b.db.upsert(
          _id,
          _row(eps: {
            'ep2': _ep(finished: true),
            'ep3': _ep(progress: '42'),
          }));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);

      final rowA = await _read(a);
      expect(rowA, await _read(b));
      final eps = rowA['episodedata'] as Map;
      expect(eps['ep1']['finished'], isTrue);
      expect(eps['ep2']['finished'], isTrue);
      expect(eps['ep3']['bookmark'], isTrue);
      expect(eps['ep3']['progress'], '42');
      expect(rowA['sort_read'], 2, reason: 'derived fields are recomputed');
    });

    test('a background refresh does not wipe user changes', () async {
      final (a, b) = await _pair(_row());

      await a.db.upsert(
          _id,
          _row(
              note: 'mine',
              rating: 4.5,
              eps: {'ep1': _ep(bookmark: true)}));
      await _tick();
      await b.db.upsert(_id, _row(source: 'refreshed'));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);

      for (final node in [a, b]) {
        final row = await _read(node);
        expect(row['note'], 'mine');
        expect(row['userRating'], 4.5);
        expect(row['episodedata']['ep1']['bookmark'], isTrue);
        expect(row['entry'], {'title': 'refreshed'});
        expect(row['lastRefreshed'], 'refreshed');
      }
    });

    test('the later edit of one field wins', () async {
      final (a, b) = await _pair(_row());
      await b.db.upsert(_id, _row(note: 'first'));
      await _tick();
      await a.db.upsert(_id, _row(note: 'second'));
      await _tick();
      await b.crdt.sync(a.crdt.syncRepo);
      expect((await _read(a))['note'], 'second');
      expect((await _read(b))['note'], 'second');
    });

    test('removing a bookmark beats an older one', () async {
      final (a, b) = await _pair(_row(eps: {'ep1': _ep(bookmark: true)}));
      await a.db.upsert(
          _id, _row(eps: {'ep1': _ep(bookmark: true, progress: '1')}));
      await _tick();
      await b.db.upsert(_id, _row());
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final eps = (await _read(a))['episodedata'] as Map;
      expect(eps['ep1']['bookmark'], isFalse);
      expect(eps['ep1']['progress'], '1');
      expect(await _read(a), await _read(b));
    });

    test('sets merge per element', () async {
      final (a, b) = await _pair(_row(categories: ['keep', 'drop']));
      await a.db.upsert(_id, _row(categories: ['keep', 'drop', 'fromA']));
      await _tick();
      await b.db.upsert(_id, _row(categories: ['keep', 'fromB']));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final row = await _read(a);
      expect(row['categories'], unorderedEquals(['keep', 'fromA', 'fromB']));
      expect(row, await _read(b));
    });

    test('per-episode sets merge per element', () async {
      Map<String, dynamic> q(List<Object> quotes) =>
          _row(eps: {'ep1': _ep(quotes: quotes)});
      final (a, b) = await _pair(q([
        {'text': 'old'}
      ]));
      await a.db.upsert(
          _id,
          q([
            {'text': 'old'},
            {'text': 'a'},
          ]));
      await _tick();
      await b.db.upsert(
          _id,
          q([
            {'text': 'b'},
          ]));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final quotes =
          (await _read(a))['episodedata']['ep1']['quotes'] as List;
      expect(
          quotes,
          unorderedEquals([
            {'text': 'a'},
            {'text': 'b'},
          ]));
    });

    test('a record link in a set survives merging', () async {
      const cat = DBRecord('category', 'c1');
      final (a, b) = await _pair(_row());
      await a.db.upsert(_id, _row(categories: [cat]));
      await _tick();
      await b.db.upsert(_id, _row(note: 'x'));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      expect((await _read(b))['categories'], [cat]);
    });

    test('a second sync changes nothing', () async {
      final (a, b) = await _pair(_row());
      await a.db.upsert(_id, _row(note: 'a'));
      await _tick();
      await b.db.upsert(_id, _row(rating: 1));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final metaA = await a.crdt.syncRepo.getSyncData(_id);
      final metaB = await b.crdt.syncRepo.getSyncData(_id);
      expect(metaA!.orderAgainst(metaB!), SyncOrder.same);
      await a.crdt.sync(b.crdt.syncRepo);
      final after = await a.crdt.syncRepo.getSyncData(_id);
      expect(after!.hlc.toString(), metaA.hlc.toString());
    });

    test('syncRecord merges concurrent edits on both sides', () async {
      final (a, b) = await _pair(_row());
      await a.db.upsert(_id, _row(note: 'a'));
      await _tick();
      await b.db.upsert(_id, _row(rating: 2));
      await _tick();
      expect(await a.crdt.syncRepo.syncRecord(b.crdt.syncRepo, _id), isTrue);
      final row = await _read(a);
      expect(row['note'], 'a');
      expect(row['userRating'], 2);
      expect(row, await _read(b));
      expect(await a.crdt.syncRepo.syncRecord(b.crdt.syncRepo, _id), isFalse);
    });

    test('merging works over HTTP', () async {
      final (a, b) = await _pair(_row(categories: ['c']));
      await a.db.upsert(
          _id, _row(categories: ['c'], eps: {'https://x.y/1': _ep(bookmark: true)}));
      await _tick();
      await b.db.upsert(_id, _row(categories: ['c', 'd'], note: 'n'));
      await _tick();

      final handler = SyncHttpHandler(repo: b.crdt.syncRepo);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen(
          (req) async => handler.handle(req, req.requestedUri.path));
      final client = SyncHttpClient(
          url: 'http://${server.address.host}:${server.port}',
          client: HttpClient());
      try {
        await a.crdt.sync(client);
      } finally {
        client.dispose();
        await sub.cancel();
        await server.close(force: true);
      }

      final row = await _read(a);
      expect(row, await _read(b));
      expect(row['note'], 'n');
      expect(row['episodedata']['https://x.y/1']['bookmark'], isTrue);
      expect(row['categories'], unorderedEquals(['c', 'd']));
    });

    test('an open reader keeps its edits and a change synced into it',
        () async {
      final (a, b) = await _pair(_row(eps: {'ep1': _ep(progress: '1')}));
      final data = await a.db.setDataClassAdapter();
      data.registerDataClass<_EntryData>(_entry, _EntryData.fromJson);
      final reader = (await data.selectDataClass<_EntryData>(_id))!;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Scrolling: changed in memory, not saved yet.
      reader.row['episodedata']['ep1']['progress'] = '50';

      await b.db.upsert(
          _id,
          _row(eps: {
            'ep1': _ep(progress: '1'),
            'ep2': _ep(bookmark: true),
          }));
      await _tick();
      await b.crdt.sync(a.crdt.syncRepo);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(reader.row['episodedata']['ep2']['bookmark'], isTrue);
      expect(reader.row['episodedata']['ep1']['progress'], '50');

      await data.save(reader);
      await _tick();
      await b.crdt.sync(a.crdt.syncRepo);

      for (final node in [a, b]) {
        final eps = (await _read(node))['episodedata'] as Map;
        expect(eps['ep2']['bookmark'], isTrue);
        expect(eps['ep1']['progress'], '50');
      }
    });

    test('a new record reaches the other side intact', () async {
      final a = await _newDb();
      final b = await _newDb();
      await a.db.upsert(
          _id, _row(eps: {'ep1': _ep(bookmark: true)}, categories: ['c']));
      await _tick();
      await b.crdt.sync(a.crdt.syncRepo);
      expect(await _read(b), await _read(a));
    });

    test('both sides adding the same record merge instead of replacing',
        () async {
      final a = await _newDb();
      final b = await _newDb();
      await a.db.upsert(_id, _row(eps: {'ep1': _ep(bookmark: true)}));
      await _tick();
      await b.db.upsert(_id, _row(eps: {'ep2': _ep(finished: true)}));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final eps = (await _read(a))['episodedata'] as Map;
      expect(eps.keys, unorderedEquals(['ep1', 'ep2']));
    });
  });

  group('deletes', () {
    test('a delete wins over an earlier refresh', () async {
      final (a, b) = await _pair(_row());
      await b.db.upsert(_id, _row(source: 'refreshed'));
      await _tick();
      await a.db.delete(_id);
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      expect(await a.db.select(_id), isNull);
      expect(await b.db.select(_id), isNull);
    });

    test('a later refresh does not bring a deleted row back', () async {
      final (a, b) = await _pair(_row());
      await a.db.delete(_id);
      await _tick();
      await b.db.upsert(_id, _row(source: 'refreshed'));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      expect(await a.db.select(_id), isNull);
      expect(await b.db.select(_id), isNull);
    });

    test('later user activity keeps a deleted row', () async {
      final (a, b) = await _pair(_row());
      await a.db.delete(_id);
      await _tick();
      await b.db.upsert(_id, _row(note: 'still reading'));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final row = await _read(a);
      expect(row['note'], 'still reading');
      expect(row['entry'], {'title': 'v1'}, reason: 'the row stays whole');
    });

    test('a row added again after a delete syncs fresh', () async {
      final (a, b) = await _pair(_row(eps: {'ep1': _ep(bookmark: true)}));
      await a.db.delete(_id);
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      await a.db.upsert(_id, _row(note: 'back'));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      final row = await _read(b);
      expect(row['note'], 'back');
      expect(row['episodedata'], isEmpty);
    });
  });

  group('stamping', () {
    Future<Map<dynamic, dynamic>> fields(_Node n) async {
      final side =
          await n.db.select(DBRecord(n.crdt.fieldsTableName, ['entry', 'e1']));
      return side['fields'] as Map;
    }

    test('a new row stores no per-field stamps', () async {
      final a = await _newDb();
      await a.db.upsert(_id, _row(eps: {'ep1': _ep(bookmark: true)}));
      await _tick();
      expect(await fields(a), isEmpty);
    });

    test('only changed paths are stamped', () async {
      final a = await _newDb();
      await a.db.upsert(_id, _row(eps: {'ep1': _ep()}));
      await _tick();
      await a.db.upsert(_id, _row(eps: {'ep1': _ep(bookmark: true)}));
      await _tick();
      expect((await fields(a)).keys, ['episodedata/ep1/bookmark']);
      await a.db.upsert(_id,
          _row(source: 'x', eps: {'ep1': _ep(bookmark: true)}, note: 'n'));
      await _tick();
      expect((await fields(a)).keys,
          unorderedEquals(['episodedata/ep1/bookmark', '@source', 'note']));
    });

    test('a change to derived fields alone is not a change', () async {
      final a = await _newDb();
      await a.db.upsert(_id, _row());
      await _tick();
      final before = await a.crdt.syncRepo.getSyncData(_id);
      await a.db.upsert(_id, _row(read: 7));
      await _tick();
      final after = await a.crdt.syncRepo.getSyncData(_id);
      expect(after!.hlc.toString(), before!.hlc.toString());
      expect(await fields(a), isEmpty);
    });

    test('undeclared fields stamp the leftover group', () async {
      final a = await _newDb();
      await a.db.upsert(_id, _row());
      await _tick();
      await a.db.upsert(_id, {..._row(), 'extra': 1});
      await _tick();
      expect((await fields(a)).keys, ['@rest']);
    });

    test('heads track every node that wrote', () async {
      final (a, b) = await _pair(_row());
      await b.db.upsert(_id, _row(note: 'b'));
      await _tick();
      final meta = await b.crdt.syncRepo.getSyncData(_id);
      expect(meta!.heads!.keys,
          unorderedEquals([a.crdt.nodeId, b.crdt.nodeId]));
    });

    test('a diff save stamps only what it changed', () async {
      final a = await _newDb();
      final data = await a.db.setDataClassAdapter();
      data.registerDataClass<_EntryData>(_entry, _EntryData.fromJson);
      final item = _EntryData('e1', _row());
      await data.save(item);
      await _tick();
      item.row = deepCopyRow(item.row)
        ..['episodedata'] = {'ep1': _ep(progress: '9')};
      await data.save(item);
      await _tick();
      expect((await fields(a)).keys, ['episodedata/ep1/progress']);
    });
  });

  group('adoption and negotiation', () {
    test('rows written before adopting fields sync with a union', () async {
      const plain = {
        SyncTable(table: _entry, version: 1, range: VersionRange.exact(1)),
      };
      final a = await _newDb(tables: plain);
      final b = await _newDb(tables: plain);
      await a.db.upsert(_id, _row());
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      await _tick();
      await a.db.upsert(_id, _row(eps: {'ep1': _ep(bookmark: true)}));
      await _tick();
      await b.db.upsert(_id, _row(eps: {'ep2': _ep(finished: true)}));
      await _tick();

      final cA = await a.db.setCrdtAdapter(tablesToSync: _tables);
      final cB = await b.db.setCrdtAdapter(tablesToSync: _tables);
      await cA.sync(cB.syncRepo);

      final eps =
          (await a.db.select(_id))['episodedata'] as Map;
      expect(eps.keys, unorderedEquals(['ep1', 'ep2']));
    });

    test('peers with different schemas refuse to sync', () async {
      final a = await _newDb();
      final b = await _newDb(tables: {
        const SyncTable(
            table: _entry,
            version: 1,
            range: VersionRange.exact(1),
            fields: FieldCrdt(lww: {'note': null})),
      });
      await expectLater(a.crdt.sync(b.crdt.syncRepo),
          throwsA(isA<VersionMismatchException>()));
    });

    test('a field table refuses to sync with a whole-row peer', () async {
      final a = await _newDb();
      final b = await _newDb(tables: {
        const SyncTable(table: _entry, version: 1, range: VersionRange.exact(1)),
      });
      await expectLater(a.crdt.sync(b.crdt.syncRepo),
          throwsA(isA<VersionMismatchException>()));
    });

    test('a v2 crdt table upgrades and keeps syncing', () async {
      final db = await AdapterSurrealDB.connect('mem://');
      await db.use(ns: 'fields', db: 'fields');
      await db.query('''
        DEFINE TABLE _version SCHEMALESS;
        DEFINE TABLE crdt SCHEMAFULL;
        DEFINE FIELD timestamp ON TABLE crdt TYPE datetime;
        DEFINE FIELD count ON TABLE crdt TYPE int;
        DEFINE FIELD deleted ON TABLE crdt TYPE bool;
        DEFINE FIELD entry ON TABLE crdt TYPE record;
        DEFINE FIELD node ON TABLE crdt TYPE string;
        UPSERT _version:crdtcrdt SET version = 2;
      ''');
      final crdt = await db.setCrdtAdapter(tablesToSync: _tables);
      await db.upsert(_id, _row());
      await _tick();
      final meta = await crdt.syncRepo.getSyncData(_id);
      expect(meta!.heads, isNotNull);
    });
  });

  group('runUnstamped', () {
    const plain = {
      SyncTable(table: _entry, version: 1, range: VersionRange.exact(1)),
    };

    for (final (name, tables) in [('whole-row', plain), ('field', _tables)]) {
      test('$name writes keep the existing timestamp', () async {
        final a = await _newDb(tables: tables);
        await a.db.upsert(_id, _row());
        await _tick();
        final before = await a.crdt.syncRepo.getSyncData(_id);

        await a.crdt.runUnstamped(() => a.db.upsert(_id, _row(note: 'migr')));
        await _tick();

        final after = await a.crdt.syncRepo.getSyncData(_id);
        expect(after!.hlc.toString(), before!.hlc.toString());
        expect((await _read(a))['note'], 'migr');
      });

      test('$name tracking resumes afterwards', () async {
        final a = await _newDb(tables: tables);
        await a.db.upsert(_id, _row());
        await _tick();
        final before = await a.crdt.syncRepo.getSyncData(_id);
        await a.crdt.runUnstamped(() async {});
        await a.db.upsert(_id, _row(note: 'tracked'));
        await _tick();
        final after = await a.crdt.syncRepo.getSyncData(_id);
        expect(after!.hlc.compareTo(before!.hlc), greaterThan(0));
      });
    }

    test('tracking resumes when the body throws', () async {
      final a = await _newDb(tables: plain);
      await expectLater(
          a.crdt.runUnstamped(() async => throw StateError('boom')),
          throwsStateError);
      await a.db.upsert(_id, _row());
      await _tick();
      expect(await a.crdt.syncRepo.getSyncData(_id), isNotNull);
    });

    test('overlapping callers keep tracking off until the last ends', () async {
      final a = await _newDb(tables: plain);
      final release = Completer<void>();
      final outer = a.crdt.runUnstamped(() => release.future);
      await a.crdt.runUnstamped(() async {});
      await a.db.upsert(_id, _row());
      await _tick();
      expect(await a.crdt.syncRepo.getSyncData(_id), isNull);
      release.complete();
      await outer;
      await a.db.upsert(_id, _row(note: 'tracked'));
      await _tick();
      expect(await a.crdt.syncRepo.getSyncData(_id), isNotNull);
    });

    test('a migration on one device does not beat newer data', () async {
      final (a, b) = await _pair(_row());
      await a.db.upsert(_id, _row(note: 'real change'));
      await _tick();
      await b.crdt.runUnstamped(
          () => b.db.upsert(_id, {..._row(), 'migrated': true}));
      await _tick();
      await a.crdt.sync(b.crdt.syncRepo);
      expect((await _read(b))['note'], 'real change');
    });
  });

  test('three devices converge under random edits', () async {
    final rng = Random(7);
    final nodes = [await _newDb(), await _newDb(), await _newDb()];
    await nodes[0].db.upsert(_id, _row());
    await _tick();
    await nodes[0].crdt.sync(nodes[1].crdt.syncRepo);
    await nodes[0].crdt.sync(nodes[2].crdt.syncRepo);

    for (var round = 0; round < 40; round++) {
      final node = nodes[rng.nextInt(3)];
      final row = await _read(node);
      final eps = Map<String, dynamic>.from(row['episodedata'] as Map);
      final key = 'ep${rng.nextInt(5)}';
      final item = Map<String, dynamic>.from(eps[key] as Map? ?? _ep());
      switch (rng.nextInt(5)) {
        case 0:
          item['bookmark'] = rng.nextBool();
        case 1:
          item['finished'] = rng.nextBool();
        case 2:
          item['progress'] = '${rng.nextInt(100)}';
        case 3:
          row['note'] = 'note$round';
        default:
          row['categories'] = rng.nextBool() ? ['c$round'] : <String>[];
      }
      eps[key] = item;
      row['episodedata'] = eps;
      await node.db.upsert(_id, row);
      await _tick();
      if (rng.nextInt(3) == 0) {
        final x = nodes[rng.nextInt(3)];
        final y = nodes[rng.nextInt(3)];
        if (!identical(x, y)) await x.crdt.sync(y.crdt.syncRepo);
      }
    }

    for (var pass = 0; pass < 2; pass++) {
      await nodes[0].crdt.sync(nodes[1].crdt.syncRepo);
      await nodes[1].crdt.sync(nodes[2].crdt.syncRepo);
      await nodes[2].crdt.sync(nodes[0].crdt.syncRepo);
    }
    final first = await _read(nodes[0]);
    expect(await _read(nodes[1]), first);
    expect(await _read(nodes[2]), first);
  });
}

Map<String, dynamic> deepCopyRow(Map<String, dynamic> row) =>
    Map<String, dynamic>.from(row);
