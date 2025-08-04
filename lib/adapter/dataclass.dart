import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:metis/client.dart';
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

class DBDataClassAdapter extends Adapter {
  final _classes = <Type, dynamic>{};
  final _cache = WeakCache<DBRecord, DBConstClass>();

  int get loadedClasses => _cache.length;

  DBDataClassAdapter({required super.db});

  Future<void> delete(DBConstClass data) async {
    if (data is DBModifiableClass && data.deleted) return;
    try {
      await db.delete(res: data.dbId);
      if (data is DBModifiableClass) data._deleted = true;
      _cache.remove(data.dbId);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> save(DBConstClass data) async {
    if (data is DBModifiableClass && data.deleted) return;
    if (data is DBModifiableClass &&
        data._loadId != data.dbId &&
        data._loadId != null) {
      // update db pos as it has changed
      await db.query(
          query: """
        BEGIN TRANSACTION;
        DELETE type::thing(\$table, \$oldid);
        CREATE type::thing(\$table, \$id) CONTENT \$data;
        COMMIT TRANSACTION;
      """
              .trim(),
          vars: {
            "table": data.dbId.tb,
            "id": data.dbId.id,
            "data": await data.toDBJson(),
            "oldid": data._loadId!.id,
          });
      _cache.remove(data._loadId);
      data._loadId = data.dbId;
      _cache[data.dbId] = data;
      return;
    }
    await db.upsert(res: data.dbId, data: await data.toDBJson());
    _cache[data.dbId] = data;
    if (data is DBModifiableClass) data._loadId = data.dbId;
  }

  Stream<T> _load<T extends DBConstClass>(
      Iterable<Map<String, dynamic>> data) async* {
    for (final item in data) {
      final id = item['id'] as DBRecord;
      if (_cache.containsKey(id)) {
        yield _cache[id] as T;
        continue;
      }
      final T dataclass = await _classes[T](item);
      if (dataclass is DBModifiableClass) {
        dataclass._loadId = id;
        if (dataclass._loadId != dataclass.dbId) {
          throw StateError(
              'Dataclass id should only be dependent on the contents of the dataclass expected $id got ${dataclass.dbId}');
        }
      }
      _cache[id] = dataclass;
      yield dataclass;
    }
  }

  void registerDataClass<T extends DBConstClass>(
      FutureOr<T> Function(Map<String, dynamic> data) loader) {
    if (_classes.containsKey(T)) {
      throw StateError('Data class $T is already registered');
    }
    _classes[T] = loader;
  }

  Stream<T> selectDataClasses<T extends DBConstClass>(
      Iterable<DBRecord> ids) async* {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    for (final id in ids) {
      final data = await db.select(res: id);
      if (data == null) continue;
      yield* _load<T>([data as Map<String, dynamic>]);
    }
  }

  Future<T?> selectDataClass<T extends DBConstClass>(DBRecord id) async {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    final data = await db.select(res: id);
    if (data == null) return null;
    return _load<T>([data as Map<String, dynamic>]).first;
  }

  Stream<T> queryDataClasses<T extends DBConstClass>({
    required String query,
    Map<String, dynamic>? vars,
  }) async* {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    final data = (await db.query(query: query, vars: vars))[0] as List<dynamic>;
    yield* _load(data.where((item) => item != null).cast());
  }

  @override
  Future<void> dispose() async {
    _cache.clear();
    _classes.clear();
  }

  @override
  Future<void> init() async {}
}
