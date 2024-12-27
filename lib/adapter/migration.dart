import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/client.dart';
import 'package:metis/adapter.dart';

typedef MigrationMigrateFunction = Future<void> Function(
    SurrealDB db, int from, int to);
typedef MigrationCreateFunction = Future<void> Function(SurrealDB db);

extension AdapterMigrationExt on AdapterSurrealDB {
  Future<MigrationAdapter> setMigrationAdapter({
    required int version,
    required String migrationName,
    required MigrationMigrateFunction onMigrate,
    required MigrationCreateFunction onCreate,
    String? name,
    String migrationTableName = "_version",
  }) async {
    return await setAdapter(
        MigrationAdapter(
          db: this,
          version: version,
          migrationName: migrationName,
          onMigrate: onMigrate,
          onCreate: onCreate,
          migrationTableName: migrationTableName,
        ),
        name: name);
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
