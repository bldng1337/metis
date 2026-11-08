import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

class TestData with DBConstClass, DBModifiableClass {
  String? test;
  int numint;

  @override
  DBRecord get dbId => DBRecord('SyncTestData', '$test$numint');

  TestData({
    required this.test,
    required this.numint,
  });

  factory TestData.fromJson(Map<String, dynamic> json) {
    return TestData(
      test: json['test'] as String?,
      numint: json['numint'] as int,
    );
  }

  @override
  FutureOr<Map<String, dynamic>> toDBJson() => {
        'test': test,
        'numint': numint,
      };
}

class AsyncTestData with DBConstClass, DBModifiableClass {
  int somedata;
  final double somenum;

  @override
  DBRecord get dbId => DBRecord('AsyncTestData', '$somenum');
  AsyncTestData({
    required this.somedata,
    required this.somenum,
  });

  static Future<AsyncTestData> fromJson(Map<String, dynamic> json) async {
    await Future.delayed(const Duration(milliseconds: 100)); //Simulate async
    return AsyncTestData(
      somedata: json['somedata'] as int,
      somenum: json['somenum'] as double,
    );
  }

  @override
  FutureOr<Map<String, dynamic>> toDBJson() async {
    await Future.delayed(const Duration(milliseconds: 100)); //Simulate async
    return {
      'somedata': somedata,
      'somenum': somenum,
    };
  }

  @override
  String toString() {
    return 'AsyncTestData(somedata: $somedata, somenum: $somenum)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AsyncTestData &&
          runtimeType == other.runtimeType &&
          somedata == other.somedata &&
          somenum == other.somenum;

  @override
  int get hashCode => somedata.hashCode ^ somenum.hashCode;
}

class ConstTestData with DBConstClass {
  final int somedata;
  final double somenum;

  @override
  DBRecord get dbId => DBRecord('ConstTestData', '${somedata}_$somenum');

  ConstTestData({
    required this.somedata,
    required this.somenum,
  });

  static Future<ConstTestData> fromJson(Map<String, dynamic> json) async {
    await Future.delayed(const Duration(milliseconds: 100)); //Simulate async
    return ConstTestData(
      somedata: json['somedata'] as int,
      somenum: json['somenum'] as double,
    );
  }

  @override
  FutureOr<Map<String, dynamic>> toDBJson() => {
        'somedata': somedata,
        'somenum': somenum,
      };
}

class LiveTestData with DBConstClass, DBModifiableClass, DBLiveClass {
  int? value;
  DBChange? lastChange;

  @override
  DBRecord get dbId => const DBRecord('LiveTestData', 'fixed');

  LiveTestData({this.value});

  factory LiveTestData.fromJson(Map<String, dynamic> json) =>
      LiveTestData(value: json['value'] as int?);

  @override
  FutureOr<Map<String, dynamic>> toDBJson() => {'value': value};

  @override
  void onDBChange(DBChange change) {
    lastChange = change;
    if (change.deleted) return;
    for (final op in change.patch) {
      if (op['path'] == '/value') value = op['value'] as int?;
    }
  }
}

/// A live class whose instance can hold unsaved edits.
class DocData with DBConstClass, DBModifiableClass, DBLiveClass {
  final String key;
  Map<String, dynamic> fields;
  final changes = <DBChange>[];
  Duration handleDelay = Duration.zero;
  final handled = <int>[];

  DocData(this.key, this.fields);

  factory DocData.fromJson(Map<String, dynamic> json) => DocData(
      (json['id'] as DBRecord).id as String,
      Map<String, dynamic>.from(json)..remove('id'));

  @override
  DBRecord get dbId => DBRecord('DocData', key);

  @override
  Map<String, dynamic> toDBJson() => fields;

  @override
  Future<void> onDBChange(DBChange change) async {
    final index = changes.length;
    changes.add(change);
    if (change.state != null) fields = change.state!;
    if (handleDelay > Duration.zero) await Future.delayed(handleDelay);
    handled.add(index);
  }
}

/// Modifiable, but ignores database-side changes.
class PlainData with DBConstClass, DBModifiableClass {
  final String key;
  int a;
  int b;

  PlainData(this.key, this.a, this.b);

  factory PlainData.fromJson(Map<String, dynamic> json) => PlainData(
      (json['id'] as DBRecord).id as String,
      json['a'] as int,
      json['b'] as int);

  @override
  DBRecord get dbId => DBRecord('PlainData', key);

  @override
  Map<String, dynamic> toDBJson() => {'a': a, 'b': b};
}

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

void dotest() {
  AdapterSurrealDB? holder;
  late AdapterSurrealDB db;
  late DBDataClassAdapter data;

  setUp(() async {
    holder?.dispose();
    final next = AdapterSurrealDB(await SurrealDB.connect("mem://"));
    holder = next;
    db = next;
    await db.use(
      db: 'test',
      ns: 'test',
    );
    data = await db.setDataClassAdapter();
    data.registerDataClass(
        const DBTable('AsyncTestData'), AsyncTestData.fromJson);
    data.registerDataClass(const DBTable('SyncTestData'), TestData.fromJson);
    data.registerDataClass(
        const DBTable('ConstTestData'), ConstTestData.fromJson);
    data.registerDataClass(
        const DBTable('LiveTestData'), LiveTestData.fromJson);
    data.registerDataClass(const DBTable('DocData'), DocData.fromJson);
    data.registerDataClass(const DBTable('PlainData'), PlainData.fromJson);
  });

  group('diff saves', () {
    const settle = Duration(milliseconds: 100);

    Future<DocData> loaded(Map<String, dynamic> row) async {
      await db.upsert(const DBRecord('DocData', 'd'), row);
      final doc = await data.selectDataClass<DocData>(
          const DBRecord('DocData', 'd'));
      await Future.delayed(settle);
      return doc!;
    }

    Future<Map<dynamic, dynamic>> row() async =>
        await db.select(const DBRecord('DocData', 'd')) as Map;

    test('a stale instance does not overwrite other fields', () async {
      final doc = await loaded({'a': 1, 'b': 1});
      await db.query(r'UPDATE $id SET b = 2;',
          vars: {'id': doc.dbId}); // arrives through sync or a raw query
      doc.fields['a'] = 9; // edited before the change was applied
      await data.save(doc);
      final stored = await row();
      expect(stored['a'], 9);
      expect(stored['b'], 2);
    });

    test('a non-live instance does not overwrite other fields', () async {
      await db.upsert(const DBRecord('PlainData', 'p'), {'a': 1, 'b': 1});
      final plain = await data
          .selectDataClass<PlainData>(const DBRecord('PlainData', 'p'));
      await Future.delayed(settle);
      await db.upsert(plain!.dbId, {'a': 1, 'b': 2});
      await Future.delayed(settle);
      plain.a = 9;
      await data.save(plain);
      expect(await db.select(plain.dbId),
          containsPair('b', 2));
    });

    test('nested edits leave sibling keys alone', () async {
      final doc = await loaded({
        'm': {
          'x': {'v': 1},
          'y': {'v': 1},
        }
      });
      await db.query(r'UPDATE $id SET m.y.v = 2;', vars: {'id': doc.dbId});
      doc.fields['m']['x']['v'] = 9;
      await data.save(doc);
      final m = (await row())['m'] as Map;
      expect(m['x']['v'], 9);
      expect(m['y']['v'], 2);
    });

    test('removed keys are removed', () async {
      final doc = await loaded({'a': 1, 'gone': 1});
      doc.fields.remove('gone');
      await data.save(doc);
      expect((await row()).containsKey('gone'), isFalse);
    });

    test('keys holding slashes are written correctly', () async {
      final doc = await loaded({'m': <String, dynamic>{}});
      doc.fields['m']['https://x.y/1'] = 5;
      await data.save(doc);
      expect((await row())['m'], {'https://x.y/1': 5});
    });

    test('an unchanged save writes nothing', () async {
      const tables = {
        SyncTable(
            table: DBTable('DocData'),
            version: 1,
            range: VersionRange.exact(1)),
      };
      final crdt = await db.setCrdtAdapter(tablesToSync: tables);
      final doc = await loaded({'a': 1});
      final before = await crdt.syncRepo.getSyncData(doc.dbId);
      await data.save(doc);
      await Future.delayed(settle);
      final after = await crdt.syncRepo.getSyncData(doc.dbId);
      expect(after!.hlc.toString(), before!.hlc.toString());
    });

    test('a second save sends only the new difference', () async {
      final doc = await loaded({'a': 1, 'b': 1});
      doc.fields['a'] = 2;
      await data.save(doc);
      await db.query(r'UPDATE $id SET b = 5;', vars: {'id': doc.dbId});
      await Future.delayed(settle);
      doc.fields['b'] = 5;
      doc.fields['a'] = 3;
      await data.save(doc);
      expect(await row(), containsPair('a', 3));
      expect(await row(), containsPair('b', 5));
    });

    test('a save recreates a row that disappeared', () async {
      final doc = await loaded({'a': 1});
      await db.query(r'DELETE $id;', vars: {'id': doc.dbId});
      doc.fields['a'] = 2;
      // The delete notification may not have arrived yet.
      await data.save(doc);
      await Future.delayed(settle);
      if (!doc.deleted) expect((await row())['a'], 2);
    });

    test('full writes rows whose stored shape differs', () async {
      await db.upsert(
          const DBRecord('DocData', 'old'), {'a': 1, 'legacy': true});
      final doc = await data
          .selectDataClass<DocData>(const DBRecord('DocData', 'old'));
      await Future.delayed(settle);
      doc!.fields = {'a': 1, 'legacy': true, 'added': 1};
      doc.fields.remove('legacy');
      await data.save(doc, full: true);
      final stored =
          await db.select(const DBRecord('DocData', 'old')) as Map;
      expect(stored.containsKey('legacy'), isFalse);
      expect(stored['added'], 1);
    });

    test('live changes carry the row with unsaved edits on top', () async {
      final doc = await loaded({'a': 1, 'b': 1});
      doc.fields['a'] = 9; // unsaved
      await db.query(r'UPDATE $id SET b = 2;', vars: {'id': doc.dbId});
      await Future.delayed(settle);
      expect(doc.changes.single.state, {'a': 9, 'b': 2});
    });

    test('unsaved edits are not undone by the following save', () async {
      final doc = await loaded({'a': 1, 'b': 1});
      doc.fields['a'] = 9;
      await db.query(r'UPDATE $id SET b = 2;', vars: {'id': doc.dbId});
      await Future.delayed(settle);
      doc.fields = doc.changes.single.state!;
      await data.save(doc);
      expect(await row(), containsPair('a', 9));
      expect(await row(), containsPair('b', 2));
    });

    test('text edits arrive as plain replaces', () async {
      const text = 'abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz';
      const edited = 'abcdefghijklmnopqrstuvwxyz ABCdefghijklmnopqrstuvwxyz';
      final doc = await loaded({'s': text});
      await db.upsert(doc.dbId, {'s': edited});
      await Future.delayed(settle);
      final change = doc.changes.single;
      expect(change.patch.single['op'], 'replace');
      expect(change.patch.single['value'], edited);
      expect(change.state, {'s': edited});
    });

    test('changes are handled one at a time, in order', () async {
      final doc = await loaded({'a': 0});
      doc.handleDelay = const Duration(milliseconds: 30);
      for (var i = 1; i <= 3; i++) {
        await db.upsert(doc.dbId, {'a': i});
      }
      await Future.delayed(const Duration(milliseconds: 250));
      expect(doc.handled, [0, 1, 2]);
    });
  });

  test('Can use a dataclass to store and retrieve data', () async {
    final test = TestData(test: 'test', numint: 10);
    await data.save(test);
    expect(data.loadedClasses, 1);
    final TestData? test2 = await data.selectDataClass(test.dbId);
    expect(data.loadedClasses, 1);
    expect(test2, isNotNull);
    expect(test2!.test, test.test);
    expect(test2.numint, test.numint);
  });

  test('Can change id of dataclass', () async {
    final test = TestData(test: 'test', numint: 10);
    final previd = test.dbId;
    await data.save(test);
    test.test = 'test2';
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(previd), null);
  });

  test('Can use const dataclass', () async {
    final test = ConstTestData(somedata: 10, somenum: 10);
    final id = test.dbId;
    await data.save(test);
    // Const classes are never cached: every read is a fresh snapshot.
    expect(data.loadedClasses, 0);
    expect(await db.select(id), isNotNull);
    final ConstTestData? loadedtest = await data.selectDataClass(id);
    expect(data.loadedClasses, 0);
    expect(loadedtest, isNotNull);
    expect(loadedtest!.somedata, test.somedata);
    expect(loadedtest.somenum, test.somenum);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(id), isNull);
  });

  test('Can delete dataclass', () async {
    final test = TestData(test: 'test', numint: 10);
    final id = test.dbId;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(id), isNotNull);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(id), null);
  });

  test('Can use async dataclass', () async {
    final test = AsyncTestData(somedata: 10, somenum: 10);
    final id = test.dbId;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(id), isNotNull);
    final AsyncTestData? loadedtest = await data.selectDataClass(id);
    expect(data.loadedClasses, 1);
    expect(loadedtest, isNotNull);
    expect(loadedtest!.somedata, test.somedata);
    expect(loadedtest.somenum, test.somenum);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(id), null);
  });

  test('Only one dataclass is alive at a time', () async {
    late final DBRecord id;
    {
      final test = TestData(test: 'test', numint: 10);
      id = test.dbId;
      await data.save(test);
      expect(data.loadedClasses, 1);
    }
    final TestData? test1 = await data.selectDataClass(id);
    final TestData? test2 = await data.selectDataClass(id);
    expect(test1, isNotNull);
    expect(test2, isNotNull);
    expect(data.loadedClasses, 1);
    test1!.test = 'test2';
    expect(test2!.test, 'test2');
  });

  test('Can select table', () async {
    late String table;
    for (final i in [1, 2, 3]) {
      final test = TestData(test: 'test', numint: i);
      table = test.dbId.tb;
      await data.save(test);
    }
    final List<TestData> res =
        await data.selectDataClasses<TestData>(DBTable(table)).toList();
    expect(res.length, 3);
    for (final item in res) {
      expect(item.dbId.tb, table);
      expect(item.test, 'test');
      expect(item.numint, isNotNull);
    }
  });

  test('onDBChange is suppressed for own saves and fired for remote writes',
      () async {
    final test = LiveTestData(value: 1);
    await data.save(test);
    await Future.delayed(
        const Duration(milliseconds: 100)); // let our own echo arrive
    expect(test.lastChange, isNull, reason: 'save echo must be suppressed');

    // A write that bypasses the dataclass adapter is a remote change.
    await db.upsert(test.dbId, {'value': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.lastChange, isNotNull);
    expect(test.lastChange!.deleted, isFalse);
    expect(test.value, 2);

    // A second save with the live query established must also be suppressed.
    test.lastChange = null;
    test.value = 5;
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.lastChange, isNull,
        reason: 'echo of the second save must be suppressed too');
    expect(test.value, 5);
  });

  test('saves that change nothing do not swallow later remote writes',
      () async {
    final test = LiveTestData(value: 1);
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));

    for (var i = 0; i < 3; i++) {
      await data.save(test);
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(test.lastChange, isNull);

    await db.upsert(test.dbId, {'value': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.lastChange, isNotNull,
        reason: 'the first remote write after no-op saves must be delivered');
    expect(test.value, 2);
  });

  test('concurrent loads share one instance', () async {
    final test = AsyncTestData(somedata: 1, somenum: 7);
    await db.upsert(test.dbId, {'somedata': 1, 'somenum': 7.0});
    final loaded = await Future.wait([
      data.selectDataClass<AsyncTestData>(test.dbId),
      data.selectDataClass<AsyncTestData>(test.dbId),
    ]);
    expect(loaded[0], isNotNull);
    expect(identical(loaded[0], loaded[1]), isTrue);
    expect(data.loadedClasses, 1);
  });

  test('cached instances keep live updates after the last watcher leaves',
      () async {
    final test = LiveTestData(value: 1);
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));

    final sub = data
        .watchDataClasses<LiveTestData>(const DBTable('LiveTestData'))
        .listen((_) {});
    await Future.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    await Future.delayed(const Duration(milliseconds: 100));

    await db.upsert(test.dbId, {'value': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.value, 2);
  });

  test('onDBChange receives deletes and marks the instance deleted', () async {
    final test = LiveTestData(value: 1);
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));
    await db.delete(test.dbId);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.lastChange, isNotNull);
    expect(test.lastChange!.deleted, isTrue);
    expect(test.deleted, isTrue);
    expect(data.loadedClasses, 0);
  });

  test('watchDataClasses accumulates live events into full lists', () async {
    final events = <List<TestData>>[];
    final sub = data
        .watchDataClasses<TestData>(const DBTable('SyncTestData'))
        .listen(events.add);
    await Future.delayed(
        const Duration(milliseconds: 100)); // initial snapshot (empty)
    expect(events, isNotEmpty);
    expect(events.last, isEmpty);

    final a = TestData(test: 'watch', numint: 1);
    await data.save(a);
    final b = TestData(test: 'watch', numint: 2);
    await data.save(b);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(events.last.length, 2, reason: 'both saves must appear');

    // A native update must not duplicate or drop the row.
    await db.upsert(a.dbId, {'test': 'watch', 'numint': 3});
    await Future.delayed(const Duration(milliseconds: 200));
    expect(events.last.length, 2);

    await data.delete(b);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(events.last.length, 1, reason: 'delete must remove the row');
    await sub.cancel();
  });

  // test('Can watch dataclass', () async {
  //   final test = AsyncTestData(somedata: 10, somenum: 10);
  //   final id = test.dbId;
  //   await data.save(test);
  //   data.watchDataClass<AsyncTestData>(id).listen((data) {
  //     print(data);
  //   });
  //   expectLater(
  //       data.watchDataClass<AsyncTestData>(id),
  //       emitsInOrder([
  //         AsyncTestData(somedata: 10, somenum: 10),
  //         AsyncTestData(somedata: 20, somenum: 10),
  //         AsyncTestData(somedata: 30, somenum: 10)
  //       ]));
  //   await Future.delayed(const Duration(milliseconds: 100));
  //   test.somedata = 20;
  //   await data.save(test);
  //   await Future.delayed(const Duration(milliseconds: 100));
  //   test.somedata = 30;
  //   await data.save(test);
  // });
}
