import 'dart:async';

import 'package:async_locks/async_locks.dart';
import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/client.dart';
import 'package:uuid/uuid.dart';

extension AdapterCrdtExt on AdapterSurrealDB {
  Future<CrdtAdapter> setCrdtAdapter({
    required Set<SyncTable> tablesToSync,
    String crdtTableName = "_crdt",
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

class ToSyncData {
  final DBNotification notification;
  final DateTime modified;
  const ToSyncData({
    required this.notification,
    required this.modified,
  });

  DBRecord get id => notification.value['id'];

  SyncData toSyncData() => SyncData(
        hlc: Hlc.zero(const Uuid().v4()),
        deleted: notification.action == Action.delete,
        entry: notification.value['id'],
      );

  @override
  String toString() {
    return "ToSyncData $notification $modified";
  }
}

class CrdtAdapterRepo extends SyncRepo {
  final CrdtAdapter adapter;

  CrdtAdapterRepo({
    required this.adapter,
  });

  Future<List<SyncData>> _querySyncData(int offset, int limit) async {
    final data = await adapter.db.query(
        query: """
                      RETURN SELECT * FROM ${adapter.crdtTableName} LIMIT \$limit START \$offset*\$limit;
                      """
            .trim(),
        vars: {"offset": offset, "limit": limit});
    final List<dynamic> list = data[0];
    return list.map((e) => SyncData.fromJson(e)).toList();
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
    final data = await adapter.db.select(res: meta.entry);
    return data;
  }

  @override
  Future<void> push(SyncData meta, dynamic data) async {
    if (!adapter.tablesToSync.any((e) => e.table.tb == meta.entry.tb)) {
      return;
    }
    //TODO: Recheck and merge meta data
    adapter._ignoredids.add(meta.entry);
    await adapter.db
        .upsert(res: adapter._getSyncRecord(meta.entry), data: meta);
    if (data == null) {
      await adapter.db.delete(res: meta.entry);
      return;
    }
    await adapter.db.upsert(
      res: meta.entry,
      data: data,
    );
  }

  @override
  Future<SyncRepoData> getSyncPointData() async {
    return SyncRepoData(
        version: 1,
        entries: (await adapter.db
                .query(query: 'COUNT(SELECT * FROM ${adapter.crdtTableName})'))
            .first,
        tables: adapter.tablesToSync);
  }
}

extension on SyncData {
  void update(ToSyncData tosync) {
    switch (tosync.notification.action) {
      case Action.create:
        deleted = false;
        break;
      case Action.update:
        deleted = false;
        break;
      case Action.delete:
        deleted = true;
        break;
    }
    hlc = hlc.increment(wallTime: tosync.modified);
  }
}

class CrdtAdapter extends Adapter {
  /// The name of the table that stores the CRDT data.
  /// **Warning:** Dont use User controlled Strings here as it wont get checked against injection attacks.
  final String crdtTableName;

  /// Name of the migration table that should be used.
  final String migrationTableName;

  /// The tables that should be synced.
  final Set<SyncTable> tablesToSync;
  static const version = 1;

  final Lock _synclock = Lock();
  final List<DBRecord> _ignoredids = List.empty(growable: true);
  final List<ToSyncData> _tosyncdata = List.empty(growable: true);

  CrdtAdapter({
    required super.db,
    required this.tablesToSync,
    this.crdtTableName = "_crdt",
    this.migrationTableName = "_version",
  })  : assert(crdtTableName.isNotEmpty),
        assert(migrationTableName.isNotEmpty),
        assert(tablesToSync.isNotEmpty),
        assert(crdtTableName.contains(" ") == false),
        assert(migrationTableName.contains(" ") == false);

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
    await db.query(
        query: """
        DEFINE TABLE $crdtTableName SCHEMAFULL;
        DEFINE FIELD hlc ON TABLE $crdtTableName TYPE string;
        DEFINE FIELD deleted ON TABLE $crdtTableName TYPE bool;
        DEFINE FIELD entry ON TABLE $crdtTableName TYPE record;
        """
            .trim());
  }

  Future<void> onMigrate(SurrealDB db, int from, int to) async {}

  @override
  Future<void> dispose() async {
    await _syncWorker(force: true);
  }

  _initTableSync() {
    for (final synctable in tablesToSync) {
      db.watch(res: synctable.table).listen((event) {
        if (_ignoredids.contains(event.value["id"])) {
          _ignoredids.remove(event.value["id"]);
          return;
        }
        if (_tosyncdata.any(
            (tosync) => tosync.notification.value["id"] == event.value["id"])) {
          _tosyncdata.removeWhere(
              (tosync) => tosync.notification.value["id"] == event.value["id"]);
        }
        _tosyncdata.add(
            ToSyncData(notification: event, modified: DateTime.now().toUtc()));
        _syncWorker();
      });
    }
  }

  DBRecord _getSyncRecord(DBRecord record) {
    return DBRecord(crdtTableName, "${record.tb}_${record.id}");
  }

  Future<void> waitSync() async {
    await _syncWorker(force: true);
  }

  Future<SyncData?> _getSyncData(DBRecord id) async {
    final entry = await db.select(
      res: _getSyncRecord(id),
    );
    if (entry != null && entry.isNotEmpty) {
      return SyncData.fromJson(entry);
    } else {
      return null;
    }
  }

  Future<void> _syncWorker({bool force = false}) async {
    if (_synclock.locked && !force) return;
    await _synclock.run(() async {
      while (_tosyncdata.isNotEmpty) {
        final tosync = _tosyncdata.removeAt(0);
        final SyncData syncdata =
            (await _getSyncData(tosync.id)) ?? tosync.toSyncData();
        syncdata.update(tosync);
        await db.upsert(
          res: _getSyncRecord(tosync.id),
          data: syncdata,
        );
      }
    });
  }

  Future<void> sync(SyncRepo remote,
      {int chunkSize = 50,
      void Function(int progress, int total)? onProgress}) async {
    await syncRepo.sync(remote, chunkSize: chunkSize, onProgress: onProgress);
  }

  SyncRepo get syncRepo => CrdtAdapterRepo(adapter: this);
}


