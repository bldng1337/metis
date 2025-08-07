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

void main() {
  AdapterSurrealDB? _db;
  late AdapterSurrealDB db;
  late DBDataClassAdapter data;

  setUp(() async {
    if (_db != null) {
      _db!.dispose();
    }
    _db = await AdapterSurrealDB.newMem();
    db = _db!;
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    data.registerDataClass(ConstTestData.fromJson);
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
    expect(await db.select(res: previd), null);
  });

  test('Can use const dataclass', () async {
    final test = ConstTestData(somedata: 10, somenum: 10);
    final id = test.dbId;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(res: id), isNotNull);
    final ConstTestData? loadedtest = await data.selectDataClass(id);
    expect(data.loadedClasses, 1);
    expect(loadedtest, isNotNull);
    expect(loadedtest!.somedata, test.somedata);
    expect(loadedtest.somenum, test.somenum);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(res: id), null);
  });

  test('Can delete dataclass', () async {
    final test = TestData(test: 'test', numint: 10);
    final id = test.dbId;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(res: id), isNotNull);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(res: id), null);
  });

  test('Can use async dataclass', () async {
    final test = AsyncTestData(somedata: 10, somenum: 10);
    final id = test.dbId;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(res: id), isNotNull);
    final AsyncTestData? loadedtest = await data.selectDataClass(id);
    expect(data.loadedClasses, 1);
    expect(loadedtest, isNotNull);
    expect(loadedtest!.somedata, test.somedata);
    expect(loadedtest.somenum, test.somenum);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(res: id), null);
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

  test('Can watch dataclass', () async {
    final test = AsyncTestData(somedata: 10, somenum: 10);
    final id = test.dbId;
    await data.save(test);
    expectLater(
        data.watchDataClass<AsyncTestData>(id),
        emitsInOrder([
          AsyncTestData(somedata: 10, somenum: 10),
          AsyncTestData(somedata: 20, somenum: 10),
          AsyncTestData(somedata: 30, somenum: 10)
        ]));
    await Future.delayed(const Duration(milliseconds: 100));
    test.somedata = 20;
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));
    test.somedata = 30;
    await data.save(test);
  });
}
