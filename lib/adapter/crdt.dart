import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/client.dart';
import 'package:metis/store.dart';
import 'package:uuid/uuid.dart';

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
  /// Version of the sync repo protocol (wire format of /querySyncData and the
  /// push semantics). Bumped when the format changes so mixed-version peers
  /// fail negotiation with VersionMismatchException instead of
  /// misinterpreting each other's requests. v2: offset pagination -> cursor
  /// pagination, push applies only strictly-newer HLCs.
  static const version = 2;

  final CrdtAdapter adapter;

  CrdtAdapterRepo({
    required this.adapter,
  });

  Future<List<SyncData>> _querySyncData(DBRecord? after, int limit) async {
    // Keyset pagination (see SyncRepo.querySyncData): the cursor is the last
    // row's record id, which stays valid while rows are inserted concurrently.
    final data = await adapter.db.query(
        """
              RETURN SELECT * FROM type::table(\$table) ${after == null ? '' : 'WHERE id > \$after'} ORDER BY id LIMIT \$limit;
              """
            .trim(),
        vars: {
          "limit": limit,
          "table": adapter.crdtTableName,
          if (after != null) "after": adapter._getSyncRecord(after),
        });
    final List<dynamic> list = data[0];
    return list.map((e) => SyncData.fromDB(e)).toList();
  }

  @override
  Stream<SyncData> querySyncData(DBRecord? after, int limit) {
    return _querySyncData(after, limit).asStream().expand((e) => e);
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
    final payload =
        data is Map ? (Map<String, dynamic>.from(data)..remove('id')) : data;
    // The initiator compares HLCs before pushing, but between its comparison
    // and this apply a concurrent sync or live push may have written a newer
    // version to this row. Apply only if the incoming HLC is strictly newer;
    // an equal HLC is the same write (a no-op that must not restamp the row),
    // an older one loses last-write-wins. The check and the writes share one
    // ID-based transaction, so they are atomic even while other pushes run
    // concurrently on the same connection; writeTransaction retries the
    // whole body when such a concurrent writer makes the store reject the
    // commit. (ID-based transactions, not raw BEGIN/COMMIT strings: those
    // bind to the session, and a second concurrent one on the same
    // connection fails the query.)
    await adapter.db.writeTransaction((txn) async {
      final currRow = await txn.select(adapter._getSyncRecord(meta.entry));
      if (currRow != null) {
        final curr = SyncData.fromDB(Map<String, dynamic>.from(currRow as Map));
        if (meta.hlc.compareTo(curr.hlc) <= 0) return;
      }
      if (data == null) {
        // Raw DELETE instead of the delete method: the record is not
        // guaranteed to exist, and deleting a missing record must not fail.
        await txn.query('DELETE FROM \$entry;', vars: {'entry': meta.entry});
      } else {
        await txn.query('UPSERT \$entry CONTENT \$data;',
            vars: {'entry': meta.entry, 'data': payload});
      }
      await txn.query('UPSERT \$meta CONTENT \$crdt;', vars: {
        'meta': adapter._getSyncRecord(meta.entry),
        'crdt': meta.toDB(),
      });
    });
  }

  @override
  Future<SyncRepoData> getSyncPointData() async {
    return SyncRepoData(
        version: version,
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
  static const version = 2;

  static bool _validIdentifier(String name) =>
      RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name);

  static void _checkIdentifier(String name, String what) {
    if (!_validIdentifier(name)) {
      throw ArgumentError.value(name, what,
          'must be a valid identifier (alphanumeric and underscore only)');
    }
  }

  CrdtAdapter({
    required super.db,
    required this.tablesToSync,
    this.crdtTableName = "crdt",
    this.migrationTableName = "_version",
  }) {
    if (crdtTableName.isEmpty) {
      throw ArgumentError.value(
          crdtTableName, 'crdtTableName', 'must not be empty');
    }
    if (migrationTableName.isEmpty) {
      throw ArgumentError.value(
          migrationTableName, 'migrationTableName', 'must not be empty');
    }
    if (tablesToSync.isEmpty) {
      throw ArgumentError.value(
          tablesToSync, 'tablesToSync', 'must not be empty');
    }
    _checkIdentifier(crdtTableName, 'crdtTableName');
    _checkIdentifier(migrationTableName, 'migrationTableName');
    for (final t in tablesToSync) {
      _checkIdentifier(t.table.tb, 'synced table name');
    }
  }

  String? _nodeId;

  String get nodeId {
    final node = _nodeId;
    if (node == null) {
      throw StateError('nodeId accessed before init()');
    }
    return node;
  }

  Future<String> _ensureNodeId() async {
    final store = KeyValueStore(db, migrationTableName);
    const key = 'crdt_node';
    String? node;
    try {
      node = await store.get(key) as String?;
    } catch (_) {
      // Selecting from a table that does not exist yet errors instead of returning null. The set below creates it implicitly.
    }
    if (node == null) {
      node = const Uuid().v4();
      await store.set(key, node);
    }
    if (!Uuid.isValidUUID(fromString: node)) {
      throw StateError('Stored CRDT node id is not a valid UUID: $node');
    }
    return node;
  }

  @override
  Future<void> init() async {
    _nodeId = await _ensureNodeId();
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
        DEFINE FIELD node ON TABLE $crdtTableName TYPE string COMMENT 'The node id of the replica that last wrote the record';
        """
        .trim());
  }

  Future<void> onMigrate(SurrealDB db, int from, int to) async {
    if (from < 2) {
      await db.query(
          'DEFINE FIELD IF NOT EXISTS node ON TABLE $crdtTableName TYPE string '
          'MIGRATE EXISTING ROWS AS v2_node_backfill USING "";');
      await db.query('UPDATE type::table(\$table) SET node = \$node;', vars: {
        "table": crdtTableName,
        "node": nodeId,
      });
    }
  }

  Future<void> _initTableSync() async {
    for (final table in tablesToSync) {
      //TODO: This is a possible injection point but as far as I can tell its not possible to use the vars for a define statement 2.0
      await db.query("""
          DEFINE EVENT OVERWRITE sync ON ${table.table.tb} THEN {
          // Writes that do not change the record (remote applies of data we
          // already hold, re-saves of unchanged state) must not restamp the
          // CRDT row: the new HLC would look like a fresh local change and
          // echo back and forth between replicas forever.
          IF \$before == \$after { RETURN NULL; };
          let \$entry = type::record("$crdtTableName",[record::tb(\$value.id),record::id(\$value.id)]);
          let \$now = time::now();
          let \$deleted = \$event == "DELETE";
          let \$curr = SELECT * from ONLY \$entry;
          IF \$curr==null {
              UPSERT \$entry SET timestamp=\$now, count=0, deleted=\$deleted, entry=\$value.id, node='$nodeId';
              RETURN NULL;
          };
          IF \$now <= \$curr.timestamp {
              UPSERT \$entry SET timestamp=\$curr.timestamp, count=\$curr.count+1, deleted=\$deleted, entry=\$value.id, node='$nodeId';
              RETURN NULL;
          };
          UPSERT \$entry SET timestamp=\$now, count=0, deleted=\$deleted, entry=\$value.id, node='$nodeId';
          RETURN NULL;
          };
        """);
    }
  }

  Future<void> removeSyncTable(SyncTable table) async {
    final name = table.table.tb;
    _checkIdentifier(name, 'synced table name');
    await db.query('REMOVE EVENT IF EXISTS sync ON $name;');
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

  final _changeController = StreamController<DBRecord>.broadcast();
  StreamSubscription<Notification>? _changeLiveSub;
  bool _changeLiveStarting = false;

  /// Live feed of local changes: yields the record id of every entry whose
  /// CRDT row changed, in write order. Backed by a LIVE SELECT on the CRDT
  /// table, established lazily on the first watch and shared by all
  /// listeners; it re-establishes itself with a fixed delay when the
  /// subscription ends or fails, and errors are forwarded on the stream.
  Stream<DBRecord> watchChanges() {
    _ensureChangeLive();
    return _changeController.stream;
  }

  void _ensureChangeLive() {
    if (_changeLiveSub != null || _changeLiveStarting) return;
    _changeLiveStarting = true;
    () async {
      try {
        final result = await db.query('LIVE SELECT * FROM $crdtTableName;');
        final id = result[0];
        final liveId =
            id is UuidValue ? id : UuidValue.fromString(id as String);
        _changeLiveSub = db.liveOf(liveId).listen((event) {
          final entry = _changeEntry(event);
          if (entry != null && !_changeController.isClosed) {
            _changeController.add(entry);
          }
        }, onError: (Object e, StackTrace s) {
          if (!_changeController.isClosed) _changeController.addError(e, s);
          _teardownChangeLive();
        }, onDone: _teardownChangeLive);
      } catch (e, s) {
        if (!_changeController.isClosed) _changeController.addError(e, s);
        _changeLiveStarting = false;
        _scheduleChangeLiveRetry();
      }
    }();
  }

  /// A dead live query must be replaced, or no further changes would be
  /// reported; retrying forever with a fixed delay keeps live consumers
  /// working across engine restarts without them knowing about it.
  void _teardownChangeLive() {
    _changeLiveSub?.cancel();
    _changeLiveSub = null;
    _changeLiveStarting = false;
    _scheduleChangeLiveRetry();
  }

  Timer? _changeLiveRetry;

  void _scheduleChangeLiveRetry() {
    if (_changeLiveRetry != null || _changeController.isClosed) return;
    _changeLiveRetry = Timer(const Duration(seconds: 5), () {
      _changeLiveRetry = null;
      _ensureChangeLive();
    });
  }

  static DBRecord? _changeEntry(Notification event) {
    if (event.action == Action.delete) {
      // CRDT rows are tombstoned (deleted = true), never removed, so a
      // delete notification can only come from table maintenance; the entry
      // id is not recoverable from it either.
      return null;
    }
    final result = event.result;
    if (result is Map) {
      final entry = result['entry'];
      if (entry is DBRecord) return entry;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _changeController.close();
    _changeLiveRetry?.cancel();
    await _changeLiveSub?.cancel();
  }
}
