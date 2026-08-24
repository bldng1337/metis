import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
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

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

void dotest() {
  AdapterSurrealDB? _db;
  late AdapterSurrealDB db;
  late DBDataClassAdapter data;

  setUp(() async {
    if (_db != null) {
      _db!.dispose();
    }
    _db = AdapterSurrealDB(await SurrealDB.connect("mem://"));
    db = _db!;
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
