import 'dart:async';

import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/client.dart';

extension AdapterCrdtExt on AdapterSurrealDB {
  Future<CrdtAdapter> setCrdtAdapter({
    required Set<SyncTable> tablesToSync,
    String crdtTableName = "crdt",
    String migrationTableName = "_version",
    String? name,
  }) async {
    return await setAdapter(
        CrdtAdapter(
          db: this,
          tablesToSync: tablesToSync,
          crdtTableName: crdtTableName,
          migrationTableName: migrationTableName,
        ),
        name: name);
  }
}

class CrdtAdapterRepo extends SyncRepo {
  final CrdtAdapter adapter;

  CrdtAdapterRepo({
    required this.adapter,
  });

  Future<List<SyncData>> _querySyncData(int offset, int limit) async {
    final data = await adapter.db.query(
        """
              RETURN SELECT * FROM type::table(\$table) LIMIT \$limit START \$offset*\$limit;
              """
            .trim(),
        vars: {
          "offset": offset,
          "limit": limit,
          "table": adapter.crdtTableName
        });
    final List<dynamic> list = data[0];
    return list.map((e) => SyncData.fromDB(e)).toList();
  }

  @override
  Stream<SyncData> querySyncData(int offset, int limit) {
    return _querySyncData(offset, limit).asStream().expand((e) => e);
  }

  @override
  Future<SyncData?> getSyncData(DBRecord id) async {
    if (!adapter.tablesToSync.any((e) => e.table.tb == id.tb)) return null;
    return adapter._getSyncData(id);
  }

  @override
  Future<dynamic> pull(SyncData meta) async {
    if (!adapter.tablesToSync.any((e) => e.table.tb == meta.entry.tb)) {
      return null;
    }
    final data = await adapter.db.select(meta.entry);
    return data;
  }

  @override
  Future<void> push(SyncData meta, dynamic data) async {
    if (!adapter.tablesToSync.any((e) => e.table.tb == meta.entry.tb)) {
      return;
    }
    await adapter.db.upsert(
      adapter._getSyncRecord(meta.entry),
      meta.toDB(),
    );
    if (data == null) {
      // We can't use the delete method here as the current version of surrealdb uses ONLY for the delete method that needs the record to exist which we cannot guarantee
      await adapter.db.query("DELETE FROM \$entry", vars: {
        "entry": meta.entry,
      });
      return;
    }
    await adapter.db
        .upsert(meta.entry, data); //TODO: Disable sync for this upsert
  }

  @override
  Future<SyncRepoData> getSyncPointData() async {
    return SyncRepoData(
        version: 1,
        entries: (await adapter.db
                .query('COUNT(SELECT * FROM type::table(\$table))', vars: {
          "table": adapter.crdtTableName,
        }))
            .first,
        tables: adapter.tablesToSync);
  }
}

class CrdtAdapter extends Adapter {
  /// The name of the table that stores the CRDT data.
  final String crdtTableName;

  /// Name of the migration table that should be used.
  final String migrationTableName;

  /// The tables that should be synced.
  final Set<SyncTable> tablesToSync;
  static const version = 1;

  CrdtAdapter({
    required super.db,
    required this.tablesToSync,
    this.crdtTableName = "crdt",
    this.migrationTableName = "_version",
  })  : assert(crdtTableName.isNotEmpty),
        assert(migrationTableName.isNotEmpty),
        assert(tablesToSync.isNotEmpty),
        assert(crdtTableName.contains(" ") == false),
        assert(migrationTableName.contains(" ") == false),
        assert(RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(crdtTableName)),
        assert(RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(migrationTableName));

  @override
  Future<void> init() async {
    final migration = MigrationAdapter(
      db: db,
      version: version,
      migrationName: "crdt$crdtTableName",
      onMigrate: onMigrate,
      onCreate: onCreate,
      migrationTableName: migrationTableName,
    );
    await migration.init();
    await migration.dispose();
    await _initTableSync();
  }

  Future<void> onCreate(SurrealDB db) async {
    //This is a possible injection point but as far as I can tell its not possible to use the vars for a define statement
    await db.query("""
        DEFINE TABLE $crdtTableName SCHEMAFULL;
        DEFINE FIELD timestamp ON TABLE $crdtTableName TYPE datetime COMMENT 'The Timestamp of the HLC when the record was last modified';
        DEFINE FIELD count ON TABLE $crdtTableName TYPE int COMMENT 'The count of the HLC';
        DEFINE FIELD deleted ON TABLE $crdtTableName TYPE bool COMMENT 'If the record was deleted';
        DEFINE FIELD entry ON TABLE $crdtTableName TYPE record COMMENT 'The record that was modified';
        """
        .trim());
  }

  Future<void> onMigrate(SurrealDB db, int from, int to) async {}

  @override
  Future<void> dispose() async {}

  Future<void> _initTableSync() async {
    for (final table in tablesToSync) {
      //TODO: This is a possible injection point but as far as I can tell its not possible to use the vars for a define statement 2.0
      await db.query("""
          DEFINE EVENT IF NOT EXISTS sync ON ${table.table.tb} THEN {
          let \$entry = type::record("$crdtTableName",[record::tb(\$value.id),record::id(\$value.id)]);
          let \$now = time::now();
          let \$deleted = \$event == "DELETE";
          let \$curr = SELECT * from ONLY \$entry;
          IF \$curr==null {
              UPSERT \$entry SET timestamp=\$now, count=0, deleted=\$deleted, entry=\$value.id;
              RETURN NULL;
          };
          IF \$now <= \$curr.timestamp {
              UPSERT \$entry SET timestamp=\$curr.timestamp, count=\$curr.count+1, deleted=\$deleted, entry=\$value.id;
              RETURN NULL;
          };
          UPSERT \$entry SET timestamp=\$now, count=0, deleted=\$deleted, entry=\$value.id;
          RETURN NULL;
          };
        """);
    }
  }

  Future<void> removeSyncTable(SyncTable table) async {
    await db.query(
        """
      REMOVE EVENT IF EXISTS sync ON \$sync_table;
      """
            .trim(),
        vars: {
          "sync_table": table.table,
        });
  }

  DBRecord _getSyncRecord(DBRecord record) {
    return DBRecord(crdtTableName, [record.tb, record.id]);
  }

  Future<SyncData?> _getSyncData(DBRecord id) async {
    final entry = await db.select(
      _getSyncRecord(id),
    );
    if (entry != null && entry.isNotEmpty) {
      return SyncData.fromDB(entry);
    } else {
      return null;
    }
  }

  Future<void> sync(SyncRepo remote,
      {int chunkSize = 50,
      void Function(int progress, int total)? onProgress}) async {
    await syncRepo.sync(remote, chunkSize: chunkSize, onProgress: onProgress);
  }

  SyncRepo get syncRepo => CrdtAdapterRepo(adapter: this);
}
