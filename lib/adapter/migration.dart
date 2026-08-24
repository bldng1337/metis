import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/client.dart';

typedef MigrationMigrateFunction = FutureOr<void> Function(
    SurrealDB db, int from, int to);
typedef MigrationCreateFunction = FutureOr<void> Function(SurrealDB db);

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

class VersionRange {
  final int from;
  final int to;

  const VersionRange({
    required this.from,
    required this.to,
  }) : assert(from <= to, 'from must be less than or equal to to');

  const VersionRange.upto(this.to) : from = 1;
  const VersionRange.exact(this.from) : to = from;

  static int _asInt(Object? value, String what) {
    if (value is! int) {
      throw ArgumentError.value(value, what, 'must be an int');
    }
    return value;
  }

  VersionRange.fromJson(Map<String, dynamic> json)
      : this(
          from: _asInt(json['from'], 'from'),
          to: _asInt(json['to'], 'to'),
        );

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
      };

  bool match(int version) => version >= from && version <= to;
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
  }) {
    if (!MigrationAdapter._validIdentifier(migrationName)) {
      throw ArgumentError.value(migrationName, 'migrationName',
          'must be a valid identifier (alphanumeric and underscore only)');
    }
    if (!MigrationAdapter._validIdentifier(migrationTableName)) {
      throw ArgumentError.value(migrationTableName, 'migrationTableName',
          'must be a valid identifier (alphanumeric and underscore only)');
    }
  }

  static bool _validIdentifier(String name) =>
      RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name);

  @override
  Future<void> init() async {
    await db.query(
        "DEFINE TABLE IF NOT EXISTS $migrationTableName SCHEMALESS;"); // Ensure the migration table exists
    final record = _getRecord();
    final versionmeta = await db.select(record);
    final currversion = versionmeta?["version"] as int?;
    if (currversion == null) {
      await onCreate(db);
    } else if (currversion != version) {
      await onMigrate(db, currversion, version);
    }
    await db.upsert(record, {"version": version});
  }

  DBRecord _getRecord() => DBRecord(migrationTableName, migrationName);

  Future<int?> getVersion() async {
    final versionmeta = await db.select(_getRecord());
    return versionmeta?["version"] as int?;
  }

  @override
  Future<void> dispose() async {}
}
