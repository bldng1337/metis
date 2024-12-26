import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';

typedef MigrationMigrateFunction = Future<void> Function(
    SurrealDB db, int from, int to);
typedef MigrationCreateFunction = Future<void> Function(SurrealDB db);

extension MigrationAdapterExt on SurrealDB {
  Future<MigrationAdapter> initMigrationAdapter({
    required int version,
    required String migrationName,
    required MigrationMigrateFunction onMigrate,
    required MigrationCreateFunction onCreate,
    String migrationTableName = "_version",
  }) async {
    final adapter = MigrationAdapter(
      db: this,
      version: version,
      migrationName: migrationName,
      onMigrate: onMigrate,
      onCreate: onCreate,
      migrationTableName: migrationTableName,
    );
    await adapter.init();
    return adapter;
  }

  Future<void> migrate({
    required int version,
    required String migrationName,
    required MigrationMigrateFunction onMigrate,
    required MigrationCreateFunction onCreate,
    String migrationTableName = "_version",
  }) async {
    final adapter = await initMigrationAdapter(
        version: version,
        migrationName: migrationName,
        onMigrate: onMigrate,
        onCreate: onCreate);
    await adapter.migrate();
    await adapter.dispose();
    return;
  }

  Future<int?> getVersion({
    required String migrationName,
    String migrationTableName = "_version",
  }) async {
    final adapter = await initMigrationAdapter(
      version: -1,
      migrationName: migrationName,
      onMigrate: (db, from, to) async =>
          throw Exception("Migration not supported"),
      onCreate: (db) async => throw Exception("Migration not supported"),
    );
    final versionmeta = await adapter.getVersion();
    await adapter.dispose();
    return versionmeta;
  }
}

class MigrationAdapter extends Adapter {
  /// The current version of the data.
  final int version;
  /// A Name that is unique to the data.
  final String migrationName;
  /// Name of the table that stores the versions.
  final String migrationTableName;
  /// Function that is called when the data is migrated.
  final MigrationMigrateFunction onMigrate;
  /// Function that is called when the data is created.
  final MigrationCreateFunction onCreate;

  MigrationAdapter({
    required super.db,
    required this.version,
    required this.migrationName,
    required this.onMigrate,
    required this.onCreate,
    this.migrationTableName = "_version",
  });

  @override
  Future<void> init() async {}

  Future<void> migrate() async {
    final record = _getRecord();
    final versionmeta = await db.select(res: record);
    final currversion = versionmeta?["version"] as int?;
    await db.upsert(res: record, data: {"version": version});
    if (currversion == null) {
      await onCreate(db);
    } else if (currversion != version) {
      await onMigrate(db, currversion, version);
    }
  }

  DBRecord _getRecord() => DBRecord(migrationTableName, migrationName);

  Future<int?> getVersion() async {
    final versionmeta = await db.select(res: _getRecord());
    return versionmeta?["version"] as int?;
  }

  @override
  Future<void> dispose() async {}
}
