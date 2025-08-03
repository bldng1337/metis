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

mixin DBDataClass {
  bool _deleted = false;
  DBRecord? _loadId;

  bool get deleted => _deleted;
  Map<String, dynamic> get json;
  DBRecord get id;
}

mixin DBDataClassSaveable on DBDataClass {
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
  final _cache = WeakCache<DBRecord, DBDataClass>();

  int get loadedClasses => _cache.length;

  DBDataClassAdapter({required super.db});

  Future<void> delete(DBDataClass data) async {
    if (data.deleted) return;
    try {
      await db.delete(res: data.id);
      data._deleted = true;
      _cache.remove(data.id);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> save(DBDataClass data) async {
    if (data.deleted) return;
    if (data._loadId != data.id && data._loadId != null) {
      //TODO: Do this in one transaction
      await db.query(
          query: """
        BEGIN TRANSACTION;
        DELETE type::thing(\$table, \$oldid);
        CREATE type::thing(\$table, \$id) CONTENT \$data;
        COMMIT TRANSACTION;
      """
              .trim(),
          vars: {
            "table": data.id.tb,
            "id": data.id.id,
            "data": data.json,
            "oldid": data._loadId!.id,
          });
      _cache.remove(data._loadId);
      data._loadId = data.id;
      _cache[data.id] = data;
      return;
    }
    await db.upsert(res: data.id, data: data.json);
    _cache[data.id] = data;
    data._loadId = data.id;
  }

  Stream<T> _load<T extends DBDataClass>(
      Iterable<Map<String, dynamic>> data) async* {
    for (final item in data) {
      final id = item['id'] as DBRecord;
      if (_cache.containsKey(id)) {
        yield _cache[id] as T;
        continue;
      }
      final T dataclass = await _classes[T](item);
      dataclass._loadId = id;
      if (dataclass._loadId != dataclass.id) {
        throw StateError(
            'Dataclass id should only be dependent on the contents of the dataclass');
      }
      _cache[id] = dataclass;
      yield dataclass;
    }
  }

  void registerDataClass<T extends DBDataClass>(
      FutureOr<T> Function(Map<String, dynamic> data) loader) {
    if (_classes.containsKey(T)) {
      throw StateError('Data class $T is already registered');
    }
    _classes[T] = loader;
  }

  Stream<T> selectDataClasses<T extends DBDataClass>(
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

  Future<T?> selectDataClass<T extends DBDataClass>(DBRecord id) async {
    if (!_classes.containsKey(T)) {
      throw StateError('Class $T not registered');
    }
    final data = await db.select(res: id);
    if (data == null) return null;
    return _load<T>([data as Map<String, dynamic>]).first;
  }

  Stream<T> queryDataClasses<T extends DBDataClass>({
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
