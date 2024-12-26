import 'dart:async';

import 'package:async_locks/async_locks.dart';
import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/adapter/migration.dart';
import 'package:uuid/uuid.dart';

extension CrdtAdapterExt on SurrealDB {
  Future<CrdtAdapter> initCrdtAdapter({
    required Set<DBTable> tablesToSync,
    String crdtTableName = "_crdt",
    String migrationTableName = "_version",
  }) async {
    final adapter = CrdtAdapter(
      db: this,
      tablesToSync: tablesToSync,
      crdtTableName: crdtTableName,
      migrationTableName: migrationTableName,
    );
    await adapter.init();
    return adapter;
  }
}

class SyncData {
  final DBNotification notification;
  final DateTime modified;
  const SyncData({
    required this.notification,
    required this.modified,
  });
}

class CrdtAdapter extends Adapter {
  /// The name of the table that stores the CRDT data.
  /// **Warning:** Dont use User controlled Strings here as it wont get checked against injection attacks.
  final String crdtTableName;

  /// Name of the migration table that should be used.
  final String migrationTableName;

  /// The tables that should be synced.
  final Set<DBTable> tablesToSync;
  static const version = 1;

  final Lock _hlc = Lock();
  bool _syncing = false;
  final List<SyncData> _tosyncdata = List.empty(growable: true);

  CrdtAdapter({
    required super.db,
    required this.tablesToSync,
    this.crdtTableName = "_crdt",
    this.migrationTableName = "_version",
  });

  @override
  Future<void> init() async {
    await db.migrate(
      version: version,
      migrationName: "crdt$crdtTableName",
      onMigrate: onMigrate,
      onCreate: onCreate,
      migrationTableName: migrationTableName,
    );
    await _initTableSync();
  }

  Future<void> onCreate(SurrealDB db) async {
    //This is a possible injection point but as far as I can tell its not possible to use the vars for a define statement
    final name = crdtTableName.replaceAll(" ", "_");
    await db.query(
        query: """
        DEFINE TABLE $name SCHEMAFULL;
        DEFINE FIELD hlc ON TABLE $name TYPE string;
        DEFINE FIELD deleted ON TABLE $name TYPE bool;
        DEFINE FIELD entry ON TABLE $name TYPE record;
        """
            .trim());
  }

  Future<void> onMigrate(SurrealDB db, int from, int to) async {}

  @override
  Future<void> dispose() async {
    await _syncWorker(force: true);
  }

  _initTableSync() {
    for (final table in tablesToSync) {
      db.watch(res: table).listen((event) {
        if (_tosyncdata.any(
            (tosync) => tosync.notification.value["id"] == event.value["id"])) {
          _tosyncdata.removeWhere(
              (tosync) => tosync.notification.value["id"] == event.value["id"]);
        }
        _tosyncdata.add(
            SyncData(notification: event, modified: DateTime.now().toUtc()));
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

  Future<void> _syncWorker({bool force = false}) async {
    if (_hlc.locked && !force) return;
    await _hlc.run(() async {
      while (_tosyncdata.isNotEmpty) {
        final tosync = _tosyncdata.removeAt(0);
        Map<String, dynamic> hlcEntry;
        Hlc hlc;
        {
          final entry = await db.select(
            res: _getSyncRecord(tosync.notification.value["id"]),
          );
          if (entry != null && entry.isNotEmpty) {
            hlcEntry = entry;
            hlc = Hlc.parse(hlcEntry["hlc"]);
          } else {
            hlc = Hlc.zero(const Uuid().v4());
            hlcEntry = {
              "hlc": hlc.toString(),
              "deleted": false,
              "entry": tosync.notification.value["id"],
            };
          }
        }
        switch (tosync.notification.action) {
          case Action.create:
            hlcEntry["deleted"] = false;
            break;
          case Action.update:
            hlcEntry["deleted"] = false;
            break;
          case Action.delete:
            hlcEntry["deleted"] = true;
            break;
        }
        hlc=hlc.increment(wallTime: tosync.modified);
        hlcEntry["hlc"] = hlc.toString();
        await db.upsert(
          res: _getSyncRecord(tosync.notification.value["id"]),
          data: hlcEntry,
        );
      }
    });
  }

  Future<void> mergeCrdt(CrdtAdapter other, {int chunkSize = 50}) async {
    await waitSync();
    other.waitSync();
    await merge(other.db, chunkSize: chunkSize);
    await other.merge(db, chunkSize: chunkSize);
  }

  Future<void> merge(SurrealDB other, {int chunkSize = 50}) async {
    await _syncWorker(force: true);
    _syncing = true;
    await _hlc.run(() async {
      if (await other.getVersion(
              migrationName: "crdt$crdtTableName",
              migrationTableName: migrationTableName) !=
          version) {
        throw Exception("Incompatible version");
      }
      int offset = 0;
      while (true) {
        final [syncdata] = await other.query(query: """
                      SELECT * FROM $crdtTableName LIMIT \$limit START \$offset*\$limit;
                      """, vars: {"offset": offset++, "limit": chunkSize});
        if (syncdata == null || syncdata.isEmpty) break;
        for (final sync in syncdata) {
          await _syncEntry(sync, other);
        }
      }
    });
    await Future.value(); // let watch worker run
    _syncing = false;
  }

  Future<void> _syncEntry(sync, SurrealDB other) async {
    final localEntry = await db.select(res: sync["id"] as DBRecord);
    if (localEntry == null) {
      await db.insert(res: sync["id"] as DBRecord, data: sync);
      await db.insert(
        res: sync["entry"] as DBRecord,
        data: await other.select(res: sync["entry"] as DBRecord),
      );
      return;
    }
    final localHlc = Hlc.parse(localEntry["hlc"]);
    final remoteHlc = Hlc.parse(sync["hlc"]);
    if (localHlc.compareTo(remoteHlc) >= 0) {
      return;
    }
    await db.updateContent(
      res: sync["id"] as DBRecord,
      data: sync,
    );
    if (sync["deleted"]) {
      await db.delete(res: sync["entry"] as DBRecord);
    } else {
      await db.upsert(
        res: sync["entry"] as DBRecord,
        data: await other.select(res: sync["entry"] as DBRecord),
      );
    }
  }
}
