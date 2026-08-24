import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

void dotest() {
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
    db = await AdapterSurrealDB.connect("mem://");
    await db.use(
      db: 'test',
      ns: 'test',
    );
    crdt = await db.setCrdtAdapter(
      tablesToSync: tables,
    );
    db2 = await AdapterSurrealDB.connect("mem://");
    await db2.use(
      db: 'test',
      ns: 'test',
    );
    crdt2 = await db2.setCrdtAdapter(
      tablesToSync: tables,
    );
  });

  test('Sync data from one db to another', () async {
    final res = await db.insert(const DBTable('test'), {'test': 1});
    final id = res[0]["id"] as DBRecord;
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.sync(crdt.syncRepo);

    final data1 = await db.select(id);
    final data2 = await db2.select(id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
  });

  test('Sync data both ways', () async {
    final res1 = await db.insert(const DBTable('test'), {'test': 1});
    final id1 = res1[0]["id"] as DBRecord;
    final res2 = await db2.insert(const DBTable('test'), {'test': 2});
    final id2 = res2[0]["id"] as DBRecord;
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.sync(crdt.syncRepo);

    final data11 = await db.select(id1);
    final data12 = await db.select(id2);
    final data21 = await db2.select(id1);
    final data22 = await db2.select(id2);
    expect(data11, isNotNull);
    expect(data12, isNotNull);
    expect(data21, isNotNull);
    expect(data22, isNotNull);
    expect(data11['test'], data21['test']);
    expect(data12['test'], data22['test']);
  });

  test('Sync overwrite last write wins', () async {
    const id = DBRecord('test', 'test');
    await db.upsert(id, {'test': 1});
    await Future.delayed(const Duration(milliseconds: 1000));
    await db2.upsert(id, {'test': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    await crdt2.sync(crdt.syncRepo);
    final data1 = await db.select(id);
    final data2 = await db2.select(id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
    expect(data1['test'], 2);
  });

  test('Sync delete deletes data from both dbs', () async {
    const id = DBRecord('test', 'test');
    await db.upsert(id, {'test': 1});

    await crdt2.sync(crdt.syncRepo);
    final data1 = await db.select(id);
    final data2 = await db2.select(id);
    expect(data1, isNotNull);
    expect(data2, isNotNull);
    expect(data1['test'], data2['test']);
    await db.delete(id);
    await crdt2.sync(crdt.syncRepo);
    final data1a = await db.select(id);
    final data2a = await db2.select(id);
    expect(data1a, isNull);
    expect(data2a, isNull);
  });

  test('migrates crdt schema v1 to v2 (node backfill + event redefinition)',
      () async {
    const tables = {
      SyncTable(
        table: DBTable('test'),
        version: 1,
        range: VersionRange.exact(1),
      )
    };
    final db = await AdapterSurrealDB.connect("mem://");
    await db.use(db: 'test', ns: 'test');
    // Simulate a database written by schema v1: crdt table without the node
    // field, version record at 1, one data record with its v1 crdt row, and
    // the old event definition (no node, no OVERWRITE).
    await db.query("""
        DEFINE TABLE _version SCHEMALESS;
        DEFINE TABLE crdt SCHEMAFULL;
        DEFINE FIELD timestamp ON TABLE crdt TYPE datetime;
        DEFINE FIELD count ON TABLE crdt TYPE int;
        DEFINE FIELD deleted ON TABLE crdt TYPE bool;
        DEFINE FIELD entry ON TABLE crdt TYPE record;
        UPSERT _version:crdtcrdt SET version = 1;
        DEFINE EVENT sync ON test THEN {
          UPSERT type::record("crdt",[record::tb(\$value.id),record::id(\$value.id)]) SET timestamp=time::now(), count=0, deleted=\$event == "DELETE", entry=\$value.id;
        };
        """);
    const id = DBRecord('test', 'old');
    await db.upsert(id, {'v': 1});
    await db.upsert(const DBRecord('crdt', ['test', 'old']), {
      'timestamp': DateTime.utc(2024, 1, 1),
      'count': 0,
      'deleted': false,
      'entry': id,
    });

    final crdt = await db.setCrdtAdapter(tablesToSync: tables);

    // The migration added the field and backfilled the local node id.
    final rows = (await db.query('SELECT * FROM crdt'))[0] as List<dynamic>;
    expect(rows, isNotEmpty);
    for (final row in rows.cast<Map<String, dynamic>>()) {
      expect(row['node'], isA<String>());
      expect(Uuid.isValidUUID(fromString: row['node'] as String), isTrue,
          reason: 'v1 rows must be backfilled with a valid node id');
    }

    // The OVERWRITE-redefined event stamps the replica node on new writes.
    const id2 = DBRecord('test', 'new');
    await db.upsert(id2, {'v': 2});
    await Future.delayed(const Duration(milliseconds: 100));
    final meta = await crdt.syncRepo.getSyncData(id2);
    expect(meta, isNotNull);
    expect(meta!.hlc.nodeId, crdt.nodeId);
  });
}
