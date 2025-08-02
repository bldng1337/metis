import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';

void main() {
  setUpAll(() async => await RustLib.init());
  test('Can use a migration to migrate data', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    await db.setMigrationAdapter(
      version: 1,
      migrationName: 'testmigration',
      onMigrate: (db, from, to) {
        expect(0, 1,
            reason: 'Migration should not be called when no data exists');
      },
      onCreate: (db) async {
        await db.upsert(
          res: const DBRecord('test', 'test'),
          data: {'test': 'test', 'id': const DBRecord('test', 'test')},
        );
      },
    );
    expect(await db.select(res: const DBRecord('test', 'test')),
        {'test': 'test', 'id': const DBRecord('test', 'test')});
    db.disposeAdapters();
    await db.setMigrationAdapter(
      version: 1,
      migrationName: 'testmigration',
      onMigrate: (db, from, to) async {
        expect(1, 2,
            reason:
                'Migration should not be called when data exists and version is the same');
      },
      onCreate: (db) async {
        expect(2, 1,
            reason: 'Create function should not be called when data exists');
      },
    );
    expect(await db.select(res: const DBRecord('test', 'test')),
        {'test': 'test', 'id': const DBRecord('test', 'test')});
    db.disposeAdapters();
    await db.setMigrationAdapter(
      version: 2,
      migrationName: 'testmigration',
      onMigrate: (db, from, to) async {
        expect(from, 1);
        expect(to, 2);
        await db.upsert(
          res: const DBRecord('test', 'test'),
          data: {'test': 'test2', 'id': const DBRecord('test', 'test')},
        );
      },
      onCreate: (db) async {
        expect(3, 2,
            reason:
                'Create function should be called when data does not exist');
      },
    );
    expect(await db.select(res: const DBRecord('test', 'test')),
        {'test': 'test2', 'id': const DBRecord('test', 'test')});
  });
}
