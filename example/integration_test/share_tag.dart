import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/metis.dart';

import 'dataclass.dart' show LiveTestData, TestData;

/// Tests for clients attached to the same [shareTag] (one shared engine).
///
/// A second client attached to the same tag stands in for another isolate:
/// its raw writes are database-side changes the first client's dataclass
/// adapter must surface through its live queries.
void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

void dotest() {
  final clients = <AdapterSurrealDB>[];

  Future<AdapterSurrealDB> attach(String tag) async {
    final db = await AdapterSurrealDB.connect('mem://', shareTag: tag);
    await db.use(db: 'test', ns: 'test');
    clients.add(db);
    return db;
  }

  tearDown(() async {
    for (final db in clients.reversed) {
      await db.dispose(); // disposes the client's adapters too
    }
    clients.clear();
  });

  test('Dataclass writes are visible through a second client on the same tag',
      () async {
    final dbA = await attach('metis-share-basic');
    final dbB = await attach('metis-share-basic');
    final data = await dbA.setDataClassAdapter();
    data.registerDataClass(const DBTable('SyncTestData'), TestData.fromJson);

    final test = TestData(test: 'test', numint: 10);
    await data.save(test);

    // Without the shared engine this row lives in a different mem:// db.
    final row = await dbB.select(test.dbId) as Map;
    expect(row['numint'], 10);

    final dataB = await dbB.setDataClassAdapter();
    dataB.registerDataClass(const DBTable('SyncTestData'), TestData.fromJson);
    final TestData? loaded = await dataB.selectDataClass(test.dbId);
    expect(loaded, isNotNull);
    expect(loaded!.test, 'test');
    expect(loaded.numint, 10);
  });

  test('Updates from the database on another client fire onDBChange',
      () async {
    final dbA = await attach('metis-share-live');
    final dbB = await attach('metis-share-live');
    final data = await dbA.setDataClassAdapter();
    data.registerDataClass(const DBTable('LiveTestData'), LiveTestData.fromJson);

    final test = LiveTestData(value: 1);
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(test.lastChange, isNull, reason: 'own save must be suppressed');

    // The other client writes straight to the database.
    await dbB.upsert(test.dbId, {'value': 2});
    await Future.delayed(const Duration(milliseconds: 200));
    expect(test.lastChange, isNotNull);
    expect(test.lastChange!.deleted, isFalse);
    expect(test.value, 2);
  });

  test('Dataclass saves on one client reach another client as live changes',
      () async {
    final dbA = await attach('metis-share-cross');
    final dbB = await attach('metis-share-cross');
    final dataA = await dbA.setDataClassAdapter();
    dataA.registerDataClass(
        const DBTable('LiveTestData'), LiveTestData.fromJson);
    final dataB = await dbB.setDataClassAdapter();
    dataB.registerDataClass(
        const DBTable('LiveTestData'), LiveTestData.fromJson);

    final a = LiveTestData(value: 1);
    await dataA.save(a);
    final b = await dataB.selectDataClass<LiveTestData>(a.dbId);
    expect(b, isNotNull);
    expect(b!.value, 1);
    // B's live query registers asynchronously after the select; let it
    // settle so A's write is observed as a live event instead of racing it.
    await Future.delayed(const Duration(milliseconds: 100));

    a.value = 3;
    await dataA.save(a);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(b.lastChange, isNotNull);
    expect(b.value, 3);
    // A's own echo must still be suppressed on the writing client.
    expect(a.lastChange, isNull);
  });

  test('Deletes from another client mark the shared instance deleted',
      () async {
    final dbA = await attach('metis-share-delete');
    final dbB = await attach('metis-share-delete');
    final data = await dbA.setDataClassAdapter();
    data.registerDataClass(const DBTable('SyncTestData'), TestData.fromJson);

    final test = TestData(test: 'test', numint: 10);
    await data.save(test);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(data.loadedClasses, 1);

    await dbB.delete(test.dbId);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(test.deleted, isTrue);
    expect(data.loadedClasses, 0);
    expect(await dbA.select(test.dbId), isNull);
  });
}
