import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/metis.dart';

class TestData with DBDataClass {
  String? test;
  int numint;

  @override
  DBRecord get id => DBRecord('SyncTestData', '$test$numint');

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
  Map<String, dynamic> get json => {
        'test': test,
        'numint': numint,
      };
}

class AsyncTestData with DBDataClass {
  final int somedata;
  final double somenum;

  @override
  DBRecord get id => DBRecord('AsyncTestData', '${somedata}_$somenum');
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
  Map<String, dynamic> get json => {
        'somedata': somedata,
        'somenum': somenum,
      };
}

void main() {
  test('Can use a dataclass to store and retrieve data', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    final data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    final test = TestData(test: 'test', numint: 10);
    await data.save(test);
    expect(data.loadedClasses, 1);
    final TestData? test2 = await data.selectDataClass(test.id);
    expect(data.loadedClasses, 1);
    expect(test2, isNotNull);
    expect(test2!.test, test.test);
    expect(test2.numint, test.numint);
  });

  test('Can change id of dataclass', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    final data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    final test = TestData(test: 'test', numint: 10);
    final previd = test.id;
    await data.save(test);
    test.test = 'test2';
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(res: previd), null);
  });

  test('Can delete dataclass', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    final data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    final test = TestData(test: 'test', numint: 10);
    final id = test.id;
    await data.save(test);
    expect(data.loadedClasses, 1);
    expect(await db.select(res: id), isNotNull);
    await data.delete(test);
    expect(data.loadedClasses, 0);
    expect(await db.select(res: id), null);
  });

  test('Can use async dataclass', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    final data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    final test = AsyncTestData(somedata: 10, somenum: 10);
    final id = test.id;
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
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    final data = await db.setDataClassAdapter();
    data.registerDataClass(AsyncTestData.fromJson);
    data.registerDataClass(TestData.fromJson);
    late final DBRecord id;
    {
      final test = TestData(test: 'test', numint: 10);
      id = test.id;
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
}
