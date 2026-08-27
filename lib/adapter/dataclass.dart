import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/client.dart';
import 'package:uuid/uuid_value.dart';
import 'package:weak_cache/weak_cache.dart';

extension AdapterDataClassExt on AdapterSurrealDB {
  Future<DBDataClassAdapter> setDataClassAdapter({
    String? name,
  }) =>
      setAdapter(DBDataClassAdapter(db: this), name: name);
}

mixin DBConstClass {
  FutureOr<Map<String, dynamic>> toDBJson();
  DBRecord get dbId;
}

mixin DBModifiableClass on DBConstClass {
  bool _deleted = false;
  DBRecord? _loadId;

  /// Number of writes made through the adapter whose live echo has not
  /// arrived yet. Kept on the instance (not in an adapter-side map) so it
  /// can never outlive the instance the weak cache tracks.
  int _pendingEcho = 0;

  bool get deleted => _deleted;
}

mixin DBSaveableClass on DBConstClass {
  DBDataClassAdapter get _db;

  Future<void> save() async {
    await _db.save(this);
  }

  Future<void> delete() async {
    await _db.delete(this);
  }
}

/// A database-side change to a row, reported verbatim by the database's
/// live diff feed.
class DBChange {
  /// RFC 6902 style JSON patch ops (op: add/replace/remove) describing the
  /// committed transition. Empty when [deleted] is true.
  final List<Map<String, dynamic>> patch;

  /// Whether the row was deleted.
  final bool deleted;

  const DBChange({this.patch = const [], this.deleted = false});

  @override
  String toString() => 'DBChange(patch: $patch, deleted: $deleted)';
}

/// Opt-in live updates for modifiable dataclasses.
///
/// [onDBChange] is invoked whenever the row behind the instance changes without going through this adapter (raw queries, sync pushes, other clients). Writes made through [DBDataClassAdapter.save]/[DBDataClassAdapter.delete] on the same instance are suppressed. The patch is the database's own diff of the committed transition, so every path can be applied unconditionally to the last database state; a path intersecting locally modified (unsaved) fields is a conflict the implementor must resolve.
mixin DBLiveClass on DBModifiableClass {
  void onDBChange(DBChange change) {}
}

/// Error context handed to the per-registration [DBLiveErrorHook] when the live query for a registered table fails terminally.
class DBLiveError {
  final DBTable table;
  final Object error;
  final StackTrace stackTrace;

  const DBLiveError({
    required this.table,
    required this.error,
    required this.stackTrace,
  });

  @override
  String toString() => 'DBLiveError(table: ${table.tb}, error: $error)';
}

typedef DBDataClassLoader<T extends DBConstClass> = FutureOr<T> Function(
    Map<String, dynamic> data);
typedef DBLiveErrorHook = void Function(DBLiveError error);

class _DataClassRegistration {
  final DBTable table;
  final FutureOr<DBConstClass> Function(Map<String, dynamic> data) loader;
  final DBLiveErrorHook? onLiveError;

  _DataClassRegistration({
    required this.table,
    required this.loader,
    this.onLiveError,
  });
}

class _LiveSubscription {
  final StreamController<Notification> controller =
      StreamController<Notification>.broadcast();
  StreamSubscription<Notification>? sub;
  int watchers = 0;
  bool dead = false;

  /// Completes once the live query is registered with the database (on
  /// failure, after the error was routed through the live error handling).
  Future<void> ready = Future.value();
}

final _identifierPattern = RegExp(r'^[a-zA-Z0-9_]+$');

/// Dataclass adapter with an identity cache for modifiable classes.
///
/// The contract differs per class kind:
///
/// - [DBConstClass] instances are **never cached**. Every read fetches from
///   the database and constructs a fresh snapshot; holders own their
///   staleness. Two reads of the same record yield structurally equal but
///   distinct objects, so key by [DBConstClass.dbId] or implement value
///   equality.
/// - [DBModifiableClass] instances share one live instance per record (the
///   weak identity cache), so an in-place mutation is visible to every
///   holder without a database round trip. Database-side changes to those
///   rows are picked up through the adapter's live query: instances opting
///   into [DBLiveClass] receive [DBLiveClass.onDBChange]; instances that do
///   not keep their state (today's behavior). Deletes are always applied:
///   the instance is marked deleted and dropped from the cache.
///
/// The live query per registered table is owned by the DB client's live
/// contract; when it fails terminally, the per-registration
/// [DBLiveErrorHook]s fire and the table's cached instances are dropped
/// (they become snapshots).
class DBDataClassAdapter extends Adapter {
  final _classes = <Type, _DataClassRegistration>{};
  final _tableClasses = <String, Set<Type>>{};

  /// Identity map for modifiable classes: one live instance per record.
  final _cache = WeakCache<DBRecord, DBModifiableClass>();

  final _lives = <String, _LiveSubscription>{};

  int get loadedClasses => _cache.length;

  DBDataClassAdapter({required super.db});

  Future<void> delete(DBConstClass data) async {
    if (data is DBModifiableClass && data.deleted) return;
    await db.delete(data.dbId);
    if (data is DBModifiableClass) data._deleted = true;
    invalidate(data.dbId);
  }

  Future<void> save(DBConstClass data) async {
    if (data is DBModifiableClass && data.deleted) return;
    final json = Map<String, dynamic>.from(await data.toDBJson())..remove('id');
    // The live query must be active before the write commits so the write's
    // own echo arrives and can be counted as ours.
    await _liveFor(DBTable(data.dbId.tb)).ready;
    if (data is DBModifiableClass &&
        data._loadId != data.dbId &&
        data._loadId != null) {
      // update db pos as it has changed
      await db.query(
          """
        BEGIN TRANSACTION;
        DELETE type::record(\$table, \$oldid);
        CREATE type::record(\$table, \$id) CONTENT \$data;
        COMMIT TRANSACTION;
      """
              .trim(),
          vars: {
            "table": data.dbId.tb,
            "id": data.dbId.id,
            "data": json,
            "oldid": data._loadId!.id,
          });
      invalidate(data._loadId!);
      _afterWrite(data, data.dbId);
      return;
    }
    await db.upsert(data.dbId, json);
    _afterWrite(data, data.dbId);
  }

  /// Caches the instance (modifiable classes only) and counts the write so
  /// the incoming live echo is recognized as ours.
  void _afterWrite(DBConstClass data, DBRecord id) {
    if (data is! DBModifiableClass) return;
    _cache[id] = data;
    data._loadId = id;
    data._pendingEcho++;
  }

  /// Returns the cached instance for [item]'s id, or constructs one via the
  /// registration's loader. Only modifiable instances are cached.
  Future<T> _instantiate<T extends DBConstClass>(
      _DataClassRegistration registration, Map<String, dynamic> item) async {
    final id = item['id'];
    if (id is! DBRecord) {
      throw ArgumentError(
          'Row without a DBRecord id: ${item['id']} (${item['id'].runtimeType})');
    }
    final cached = _cache[id];
    if (cached != null) {
      if (cached is T) {
        return cached as T;
      }
      throw StateError(
          'Record $id is cached as ${cached.runtimeType} but requested as $T');
    }
    final dataclass = await registration.loader(item);
    if (dataclass is DBModifiableClass) {
      dataclass._loadId = id;
      if (dataclass._loadId != dataclass.dbId) {
        throw StateError(
            'Dataclass id should only be dependent on the contents of the dataclass expected $id got ${dataclass.dbId}');
      }
      _cache[id] = dataclass;
      _liveFor(registration.table);
    }
    return dataclass as T;
  }

  void registerDataClass<T extends DBConstClass>(
    DBTable table,
    DBDataClassLoader<T> loader, {
    DBLiveErrorHook? onLiveError,
  }) {
    if (_classes.containsKey(T)) {
      throw StateError('Data class $T is already registered');
    }
    _classes[T] = _DataClassRegistration(
        table: table, loader: loader, onLiveError: onLiveError);
    (_tableClasses[table.tb] ??= <Type>{}).add(T);
    // The live query for the table is established lazily on first use
    // (cached instance, save, watch).
  }

  Stream<T> _load<T extends DBConstClass>(
      Iterable<Map<String, dynamic>> data) async* {
    final registration = _classes[T];
    if (registration == null) {
      throw StateError('Class $T not registered');
    }
    for (final item in data) {
      yield await _instantiate<T>(registration, item);
    }
  }

  Iterable<Map<String, dynamic>> _rowsAsMaps(Object? result) => [
        if (result is Iterable)
          for (final row in result)
            if (row != null) Map<String, dynamic>.from(row as Map),
      ];

  Stream<T> selectDataClasses<T extends DBConstClass>(DBTable table) async* {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    yield* _load<T>(_rowsAsMaps(await db.select(table)));
  }

  Future<T?> selectDataClass<T extends DBConstClass>(DBRecord id) async {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    final data = await db.select(id);
    if (data == null) return null;
    return _load<T>([data.cast<String, dynamic>() as Map<String, dynamic>])
        .first;
  }

  /// Runs [query] and loads the rows of its first result set. Multi
  /// statement queries are not supported; all but the first result set are
  /// ignored.
  Stream<T> queryDataClasses<T extends DBConstClass>({
    required String query,
    Map<String, dynamic>? vars,
  }) async* {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    final data = await db.query(query, vars: vars);
    if (data.isEmpty) {
      throw StateError(
          'query returned no result sets, expected at least one statement result');
    }
    yield* _load(_rowsAsMaps(data[0]));
  }

  /// Watches [table] and repeatedly yields the full current list of
  /// records, accumulated from the initial snapshot plus live events.
  ///
  /// Modifiable instances that do not opt into [DBLiveClass] are served from
  /// the identity cache and therefore reflect their in-memory state, not
  /// database-side changes; const instances are fresh snapshots per change.
  ///
  /// A live query cannot run on a table that does not exist yet, so watching
  /// creates the table (schemaless, no-op if it exists) before subscribing.
  Stream<List<T>> watchDataClasses<T extends DBConstClass>(DBTable table) {
    final registration = _classes[T];
    if (registration == null) {
      throw StateError('Class $T not registered');
    }
    final controller = StreamController<List<T>>();
    final state = <DBRecord, T>{};
    // Events arriving before the initial snapshot completed are buffered and
    // replayed after it, so no change is lost in between.
    List<Notification>? pending = [];
    StreamSubscription<Notification>? sub;
    unawaited(() async {
      try {
        final live = _liveFor(table);
        live.watchers++;
        sub = live.controller.stream.listen(
          (event) {
            if (pending != null) {
              pending?.add(event);
              return;
            }
            unawaited(
                _applyWatchEvent(registration, state, event).then((changed) {
              if (changed && !controller.isClosed) {
                controller.add(List.of(state.values));
              }
            }));
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        await live.ready;
        final data = await db.select(table);
        if (data is List) {
          for (final row in data) {
            final map = Map<String, dynamic>.from(row as Map);
            final id = map['id'];
            if (id is! DBRecord) continue;
            state[id] = await _instantiate<T>(registration, map);
          }
        }
        if (!controller.isClosed) controller.add(List.of(state.values));
        final buffered = pending;
        pending = null;
        if (buffered == null) return;
        var changed = false;
        for (final event in buffered) {
          changed =
              await _applyWatchEvent(registration, state, event) || changed;
        }
        if (changed && !controller.isClosed) {
          controller.add(List.of(state.values));
        }
      } catch (e, s) {
        if (!controller.isClosed) controller.addError(e, s);
      }
    }());
    controller.onCancel = () async {
      await sub?.cancel();
      final live = _lives[table.tb];
      if (live == null) return;
      live.watchers--;
      if (live.watchers <= 0 && !live.dead) {
        // Last watcher left: kill the live query. The dispatch listener goes
        // down with it; a new watcher or registration re-establishes it.
        _lives.remove(table.tb);
        await live.sub?.cancel();
      }
    };
    return controller.stream;
  }

  Future<bool> _applyWatchEvent<T extends DBConstClass>(
      _DataClassRegistration registration,
      Map<DBRecord, T> state,
      Notification event) async {
    final id = event.record;
    if (id is! DBRecord) return false;
    if (event.action == Action.delete) {
      return state.remove(id) != null;
    }
    if (event.action != Action.create && event.action != Action.update) {
      return false;
    }
    final row = await _selectRow(id);
    if (row == null) return state.remove(id) != null;
    state[id] = await _instantiate<T>(registration, row);
    return true;
  }

  // --- live query management ---

  /// Establishes the live query for [table]. Registration with the database
  /// happens asynchronously; [_LiveSubscription.ready] completes once the
  /// query is active, so writes that must receive their own echo can await
  /// it. The table is created first (a live query on a missing table
  /// fails). Registration errors are routed through [_onLiveError].
  _LiveSubscription _liveFor(DBTable table) {
    final existing = _lives[table.tb];
    if (existing != null && !existing.dead) return existing;
    final live = _LiveSubscription();
    _lives[table.tb] = live;
    // The adapter itself consumes the stream for cache maintenance. Errors
    // are handled by _onLiveError through the hooks; nothing to do here.
    live.controller.stream.listen(
      (event) => unawaited(_dispatchNotification(table, event)),
      onError: (Object e, StackTrace s) {},
    );
    live.ready = _registerLive(table, live);
    return live;
  }

  Future<void> _registerLive(DBTable table, _LiveSubscription live) async {
    try {
      final name = _identifierPattern.hasMatch(table.tb)
          ? table.tb
          : '`${table.tb}`';
      await db.query('DEFINE TABLE IF NOT EXISTS $name SCHEMALESS;');
      final result = await db.query('LIVE SELECT DIFF FROM $name;');
      final id = result[0];
      final liveId = id is UuidValue ? id : UuidValue.fromString(id as String);
      live.sub = db.liveOf(liveId).listen(
            (event) => live.controller.add(event),
            onError: (Object e, StackTrace s) => _onLiveError(table, e, s),
            onDone: () => _onLiveError(
                table,
                StateError('live query for table ${table.tb} ended'),
                StackTrace.current),
          );
    } catch (e, s) {
      _onLiveError(table, e, s);
    }
  }

  void _onLiveError(DBTable table, Object error, StackTrace stackTrace) {
    final live = _lives.remove(table.tb);
    if (live == null) return;
    live.dead = true;
    if (_isMissingTableError(error)) {
      // The table does not exist yet (no data written). Nothing is cached
      // for it; stay quiet and let the next interaction re-establish the
      // subscription once the table exists.
      unawaited(live.controller.close());
      unawaited(live.sub?.cancel() ?? Future<void>.value());
      return;
    }
    live.controller.addError(error, stackTrace);
    live.controller.close();
    unawaited(live.sub?.cancel() ?? Future<void>.value());
    // The cache for this table can no longer be trusted to stay current:
    // drop it, held instances become snapshots.
    final staleIds = [
      for (final id in _cache.keys)
        if (id.tb == table.tb) id
    ];
    for (final id in staleIds) {
      // The pending echoes died with the live query; drop their counts.
      _cache.remove(id)?._pendingEcho = 0;
    }
    // Per-registration hooks: unambiguous attribution (type + table).
    for (final type in _tableClasses[table.tb] ?? const <Type>{}) {
      final hook = _classes[type]?.onLiveError;
      if (hook == null) continue;
      try {
        hook(DBLiveError(table: table, error: error, stackTrace: stackTrace));
      } catch (e, s) {
        Zone.current.handleUncaughtError(e, s);
      }
    }
  }

  bool _isMissingTableError(Object error) {
    // Matches SurrealDB's live error for tables that do not exist yet, e.g.
    // "The table 'x' does not exist".
    return error.toString().contains('does not exist');
  }

  Future<Map<String, dynamic>?> _selectRow(DBRecord id) async {
    final selected = await db.select(id);
    if (selected is Map) return Map<String, dynamic>.from(selected);
    return null;
  }

  Future<void> _dispatchNotification(DBTable table, Notification event) async {
    try {
      final id = event.record;
      if (id is! DBRecord) return;
      if (event.action == Action.delete) {
        final instance = _cache.remove(id);
        if (instance == null) return;
        instance._deleted = true;
        if (instance is DBLiveClass) {
          _invokeOnChange(instance, const DBChange(deleted: true));
        }
        return;
      }
      if (event.action != Action.create && event.action != Action.update) {
        return; // Action.unkown
      }
      final instance = _cache[id];
      if (instance == null) return; // only cached instances are tracked
      if (instance._pendingEcho > 0) {
        instance._pendingEcho--; // own echo
        return;
      }
      if (instance is! DBLiveClass) return;
      final result = event.result;
      if (result is! List) return; // the live query runs in diff mode
      final ops = [
        for (final e in result)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
      if (ops.isEmpty) return; // write did not change the row
      _invokeOnChange(instance, DBChange(patch: ops));
    } catch (e, s) {
      Zone.current.handleUncaughtError(e, s);
    }
  }

  void _invokeOnChange(DBLiveClass instance, DBChange change) {
    try {
      instance.onDBChange(change);
    } catch (e, s) {
      Zone.current.handleUncaughtError(e, s);
    }
  }

  // --- manual cache management ---

  /// Drops the cached instance for [id]. Holders keep their reference, which
  /// from now on is a snapshot; the next read constructs a fresh instance.
  /// Use this after writing through means other than this adapter.
  void invalidate(DBRecord id) {
    _cache.remove(id)?._pendingEcho = 0;
  }

  /// Drops all cached instances. See [invalidate].
  void clearCache() {
    for (final instance in _cache.values) {
      instance._pendingEcho = 0;
    }
    _cache.clear();
  }

  @override
  Future<void> dispose() async {
    for (final live in _lives.values) {
      unawaited(live.controller.close());
      await live.sub?.cancel();
    }
    _lives.clear();
    _cache.clear();
    _classes.clear();
    _tableClasses.clear();
  }

  @override
  Future<void> init() async {}
}
