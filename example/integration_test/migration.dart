import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';

void main() {
  test('Can use a migration to migrate data', () async {
    final db = await AdapterSurrealDB.newMem();
    await db.use(
      db: 'test',
      namespace: 'test',
    );
    bool migrationCalled = false;
    await db.setMigrationAdapter(
      version: 1,
      migrationName: 'testmigration',
      onMigrate: (db, from, to) {
        migrationCalled = true;
      },
      onCreate: (db) async {
        await db.upsert(
          res: const DBRecord('test', 'test'),
          data: {'test': 'test', 'id': const DBRecord('test', 'test')},
        );
      },
    );
    expect(migrationCalled, false,
        reason: 'Migration should not be called when no data exists');
    expect(await db.select(res: const DBRecord('test', 'test')),
        {'test': 'test', 'id': const DBRecord('test', 'test')});
    db.disposeAdapters();
    bool createCalled = false;
    migrationCalled = false;
    await db.setMigrationAdapter(
      version: 1,
      migrationName: 'testmigration',
      onMigrate: (db, from, to) async {
        migrationCalled = true;
      },
      onCreate: (db) async {
        createCalled = true;
      },
    );
    expect(migrationCalled, false,
        reason:
            'Migration should not be called when data exists and version is the same');
    expect(createCalled, false,
        reason: 'Create function should not be called when data exists');
    expect(await db.select(res: const DBRecord('test', 'test')),
        {'test': 'test', 'id': const DBRecord('test', 'test')});
    db.disposeAdapters();
    createCalled = false;
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
        createCalled = true;
      },
    );
    expect(createCalled, false,
        reason:
            'Create function should not be called when data already exists');
    expect(
      await db.select(res: const DBRecord('test', 'test')),
      {'test': 'test2', 'id': const DBRecord('test', 'test')},
    );
  });
}
