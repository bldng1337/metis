import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

void main() {
  late AdapterSurrealDB db;
  late AdapterSurrealDB db2;
  late CrdtAdapter crdt;
  late CrdtAdapter crdt2;

  setUp(() async {
    const tables = {
      SyncTable(
        table: DBTable('test'),
        version: 1,
        range: VersionRange.exact(1),
      )
    };
    db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    crdt = await db.setCrdtAdapter(
      tablesToSync: tables,
    );
    db2 = await AdapterSurrealDB.newMem();
    await db2.use(
      db: 'test',
      namespace: 'test',
    );
    crdt2 = await db2.setCrdtAdapter(
      tablesToSync: tables,
    );
  });

  test('Sync data from one db to another', () async {
    const id = DBRecord('test', 'test');
    await db.insert(res: id, data: {'test': 1});
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.waitSync();
    await crdt.waitSync();
    await crdt2.sync(crdt.syncRepo);

    final data1 = await db.select(res: id);
    final data2 = await db2.select(res: id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
  });

  test('Sync data both ways', () async {
    const id = DBRecord('test', 'test');
    const id2 = DBRecord('test', 'test2');
    await db.insert(res: id, data: {'test': 1});
    await db2.insert(res: id2, data: {'test': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.waitSync();
    await crdt.waitSync();
    await crdt2.sync(crdt.syncRepo);
    final data11 = await db.select(res: id);
    final data12 = await db.select(res: id2);
    final data21 = await db2.select(res: id);
    final data22 = await db2.select(res: id2);
    expect(data11, isNotNull);
    expect(data12, isNotNull);
    expect(data21, isNotNull);
    expect(data22, isNotNull);
    expect(data11['test'], data21['test']);
    expect(data12['test'], data22['test']);
  });

  test('Sync overwrite last write wins', () async {
    const id = DBRecord('test', 'test');
    await db.insert(res: id, data: {'test': 1});
    await Future.delayed(const Duration(milliseconds: 1000));
    await db2.insert(res: id, data: {'test': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.waitSync();
    await crdt.waitSync();
    await crdt2.sync(crdt.syncRepo);
    final data1 = await db.select(res: id);
    final data2 = await db2.select(res: id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
    expect(data1['test'], 2);
  });

  test('Sync delete deletes data from both dbs', () async {
    const id = DBRecord('test', 'test');
    await db.insert(res: id, data: {'test': 1});
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.waitSync();
    await crdt.waitSync();
    await crdt2.sync(crdt.syncRepo);
    final data1 = await db.select(res: id);
    final data2 = await db2.select(res: id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
    await Future.delayed(const Duration(milliseconds: 1000));
    await db.delete(res: id);
    await crdt2.waitSync();
    await crdt.waitSync();
    await crdt2.sync(crdt.syncRepo);
    final data1a = await db.select(res: id);
    final data2a = await db2.select(res: id);
    expect(data1a, isNull);
    expect(data2a, isNull);
  });
}
