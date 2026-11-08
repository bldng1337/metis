// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/adapter/json_diff.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

/// Rough overhead numbers for change tracking. Not part of test.dart.
/// Compare rows against each other; absolute times depend on the build.
void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  test('benchmark', _run, timeout: const Timeout(Duration(minutes: 20)));
}

const _sizes = [100, 1000, 3000];
const _saves = 25;
const _table = DBTable('entry');
const _id = DBRecord('entry', 'e1');

Map<String, dynamic> _recompute(Map<String, dynamic> row) {
  final eps = row['episodedata'] as Map;
  return {
    ...row,
    'sort_read': eps.values.where((e) => e['finished'] == true).length,
  };
}

const _schema = FieldCrdt(
  groups: {
    'source': ['entry', 'original'],
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

const _plainTables = {
  SyncTable(table: _table, version: 1, range: VersionRange.exact(1)),
};
const _fieldTables = {
  SyncTable(
      table: _table,
      version: 1,
      range: VersionRange.exact(1),
      fields: _schema),
};

String _key(int i) => 'https://example.org/series/1/episode/$i';

Map<String, dynamic> _bigRow(int n) {
  List<Map<String, dynamic>> episodes() => [
        for (var i = 0; i < n; i++)
          {
            'id': {'uid': _key(i)},
            'name': 'Episode number $i',
            'url': _key(i),
            'description': 'A short description of episode $i',
            'timestamp': '2026-01-01T00:00:00.000Z',
          }
      ];
  return {
    'entry': {'title': 'Series', 'episodes': episodes()},
    'original': {'title': 'Series', 'episodes': episodes()},
    'userRating': null,
    'note': null,
    'episode': 0,
    'categories': <Object>[],
    'episodedata': {
      for (var i = 0; i < n ~/ 2; i++)
        _key(i): <String, dynamic>{
          'bookmark': false,
          'finished': true,
          'progress': '$i',
          'note': null,
          'quotes': <Object>[],
        },
    },
    'sort_read': n ~/ 2,
  };
}

class _Doc with DBConstClass, DBModifiableClass, DBLiveClass {
  final Map<String, dynamic> row;
  _Doc(this.row);
  static _Doc fromJson(Map<String, dynamic> json) =>
      _Doc(Map<String, dynamic>.from(json)..remove('id'));
  @override
  DBRecord get dbId => _id;
  @override
  Map<String, dynamic> toDBJson() => row;
}

class _Snapshot with DBConstClass {
  final Map<String, dynamic> row;
  _Snapshot(this.row);
  static _Snapshot fromJson(Map<String, dynamic> json) =>
      _Snapshot(Map<String, dynamic>.from(json)..remove('id'));
  @override
  DBRecord get dbId => _id;
  @override
  Map<String, dynamic> toDBJson() => row;
}

late Directory _dir;
var _dbCount = 0;

Future<AdapterSurrealDB> _open() async {
  final path = '${_dir.path}/db${_dbCount++}'.replaceAll(r'\', '/');
  final db = await AdapterSurrealDB.connect('surrealkv://$path');
  await db.use(ns: 'bench', db: 'bench');
  await db.query('DEFINE TABLE IF NOT EXISTS entry SCHEMALESS;');
  return db;
}

double _median(List<double> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

Future<double> _timed(int runs, FutureOr<void> Function(int i) body) async {
  final samples = <double>[];
  final sw = Stopwatch();
  for (var i = 0; i < runs; i++) {
    sw
      ..reset()
      ..start();
    await body(i);
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000);
  }
  return _median(samples);
}

String _ms(double value) => value.toStringAsFixed(value < 10 ? 2 : 1);

Future<double> _saveCost(int n,
    {Set<SyncTable>? tables, required bool full}) async {
  final db = await _open();
  if (tables != null) await db.setCrdtAdapter(tablesToSync: tables);
  final data = await db.setDataClassAdapter();
  data.registerDataClass<_Doc>(_table, _Doc.fromJson);
  final doc = _Doc(_bigRow(n));
  await data.save(doc, full: true);
  final eps = doc.row['episodedata'] as Map;
  final cost = await _timed(_saves, (i) async {
    eps[_key(i % (n ~/ 2))]['progress'] = 'updated $i';
    await data.save(doc, full: full);
  });
  await db.dispose();
  return cost;
}

Future<void> _saveTable() async {
  print('BENCH');
  print('BENCH ### One progress update on one row (ms, median)');
  print('BENCH | episodes | no tracking | whole-row, full save (today) | '
      'whole-row, diff save | field, full save | field, diff save |');
  print('BENCH |---|---|---|---|---|---|');
  for (final n in _sizes) {
    final none = await _saveCost(n, full: true);
    final today = await _saveCost(n, tables: _plainTables, full: true);
    final wholeDiff = await _saveCost(n, tables: _plainTables, full: false);
    final fieldFull = await _saveCost(n, tables: _fieldTables, full: true);
    final fieldDiff = await _saveCost(n, tables: _fieldTables, full: false);
    print('BENCH | $n | ${_ms(none)} | ${_ms(today)} | ${_ms(wholeDiff)} | '
        '${_ms(fieldFull)} | ${_ms(fieldDiff)} |');
  }
}

Future<void> _loadAndNoopTable() async {
  print('BENCH');
  print('BENCH ### Reading and unchanged saves (ms, median)');
  print('BENCH | episodes | load, no baseline | load, with baseline | '
      'unchanged save | diff computation only |');
  print('BENCH |---|---|---|---|---|');
  for (final n in _sizes) {
    final db = await _open();
    final data = await db.setDataClassAdapter();
    data.registerDataClass<_Doc>(_table, _Doc.fromJson);
    data.registerDataClass<_Snapshot>(_table, _Snapshot.fromJson);
    final doc = _Doc(_bigRow(n));
    await data.save(doc, full: true);
    data.invalidate(_id);
    final plain = await _timed(_saves, (_) async {
      await data.selectDataClass<_Snapshot>(_id);
    });
    data.invalidate(_id);
    final tracked = await _timed(_saves, (_) async {
      data.invalidate(_id);
      await data.selectDataClass<_Doc>(_id);
    });
    final held = await data.selectDataClass<_Doc>(_id);
    final noop = await _timed(_saves, (_) => data.save(held!));
    final copy = deepCopyJson(doc.row);
    final diff = await _timed(_saves, (_) {
      diffJson(copy, doc.row);
    });
    print('BENCH | $n | ${_ms(plain)} | ${_ms(tracked)} | ${_ms(noop)} | '
        '${_ms(diff)} |');
    await db.dispose();
  }
}

Future<void> _storageTable() async {
  print('BENCH');
  print('BENCH ### Stamp storage after edits (KB of encoded JSON)');
  print('BENCH | episodes | row | no edits | every episode touched once | '
      'every episode, 4 fields |');
  print('BENCH |---|---|---|---|---|');
  for (final n in _sizes) {
    final db = await _open();
    final crdt = await db.setCrdtAdapter(tablesToSync: _fieldTables);
    Future<double> size() async {
      final side = await db.select(DBRecord(crdt.fieldsTableName, _id.toPair));
      return canonicalJson(side).length / 1024;
    }

    final row = _bigRow(n);
    await db.upsert(_id, row);
    final rowSize = canonicalJson(row).length / 1024;
    final none = await size();
    final eps = {
      for (var i = 0; i < n; i++)
        _key(i): <String, dynamic>{
          'bookmark': false,
          'finished': true,
          'progress': null,
          'note': null,
          'quotes': <Object>[],
        },
    };
    await db.upsert(_id, {...row, 'episodedata': eps});
    final once = await size();
    final all = {
      for (var i = 0; i < n; i++)
        _key(i): <String, dynamic>{
          'bookmark': true,
          'finished': false,
          'progress': '1',
          'note': 'note',
          'quotes': <Object>[],
        },
    };
    await db.upsert(_id, {...row, 'episodedata': all});
    final fourFields = await size();
    print('BENCH | $n | ${rowSize.round()} | ${none.toStringAsFixed(1)} | '
        '${once.round()} | ${fourFields.round()} |');
    await db.dispose();
  }
}

typedef _Side = ({AdapterSurrealDB db, CrdtAdapter crdt});

Future<_Side> _side(Set<SyncTable> tables) async {
  final db = await _open();
  final crdt = await db.setCrdtAdapter(tablesToSync: tables);
  return (db: db, crdt: crdt);
}

Future<double> _syncCost(int n, Set<SyncTable> tables,
    {required bool concurrent}) async {
  final a = await _side(tables);
  final b = await _side(tables);
  final row = _bigRow(n);
  await a.db.upsert(_id, row);
  await a.crdt.sync(b.crdt.syncRepo);
  final rowB = deepCopyJson(row);
  final cost = await _timed(10, (i) async {
    (row['episodedata'] as Map)[_key(i)]['progress'] = 'a$i';
    await a.db.upsert(_id, row);
    if (concurrent) {
      (rowB['episodedata'] as Map)[_key(i + 20)]['progress'] = 'b$i';
      await b.db.upsert(_id, rowB);
    } else {
      rowB['episodedata'] = deepCopyJson(row['episodedata']);
    }
    await a.crdt.sync(b.crdt.syncRepo);
    rowB['episodedata'] = deepCopyJson(await _episodes(a));
    row['episodedata'] = deepCopyJson(rowB['episodedata']);
  });
  await a.db.dispose();
  await b.db.dispose();
  return cost;
}

Future<Map<String, dynamic>> _episodes(_Side side) async =>
    Map<String, dynamic>.from((await side.db.select(_id))['episodedata']);

Future<void> _syncTable() async {
  print('BENCH');
  print('BENCH ### Syncing one changed row in-process, both directions '
      '(ms, median; includes re-reading the row between runs)');
  print('BENCH | episodes | whole-row, one side changed | field, one side '
      'changed | field, both sides changed (merge) |');
  print('BENCH |---|---|---|---|');
  for (final n in [100, 1000, 3000]) {
    final whole = await _syncCost(n, _plainTables, concurrent: false);
    final field = await _syncCost(n, _fieldTables, concurrent: false);
    final merge = await _syncCost(n, _fieldTables, concurrent: true);
    print('BENCH | $n | ${_ms(whole)} | ${_ms(field)} | ${_ms(merge)} |');
  }
}

Future<void> _idleSyncTable() async {
  print('BENCH');
  print('BENCH ### Sync with nothing to do, 500 small rows (ms, median)');
  print('BENCH | whole-row | field |');
  print('BENCH |---|---|');
  Future<double> run(Set<SyncTable> tables) async {
    final a = await _side(tables);
    final b = await _side(tables);
    for (var i = 0; i < 500; i++) {
      await a.db.upsert(DBRecord('entry', 'r$i'), {'note': 'n$i'});
    }
    await a.crdt.sync(b.crdt.syncRepo);
    final cost = await _timed(5, (_) => a.crdt.sync(b.crdt.syncRepo));
    await a.db.dispose();
    await b.db.dispose();
    return cost;
  }

  print('BENCH | ${_ms(await run(_plainTables))} | '
      '${_ms(await run(_fieldTables))} |');
}

extension on DBRecord {
  List<Object?> get toPair => [tb, id];
}

Future<void> _run() async {
  _dir = await Directory.systemTemp.createTemp('metis_bench');
  await _saveTable();
  await _loadAndNoopTable();
  await _storageTable();
  await _syncTable();
  await _idleSyncTable();
}
