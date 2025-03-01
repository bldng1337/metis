import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';

class KeyValueStore {
  final SurrealDB db;
  final String tableName;
  KeyValueStore(this.db, this.tableName);

  Future<void> set(String key, dynamic value) async {
    await db.upsert(
      res: DBRecord(tableName, key),
      data: {"value": value},
    );
  }

  Future<dynamic> get(String key) async {
    final record = await db.select(res: DBRecord(tableName, key));
    return record?["value"];
  }

  Stream<String> watch(String key) {
    return db.watch(res: DBRecord(tableName, key)).map((event) {
      return event.value["value"];
    });
  }

  Future<bool> contains(String key) async {
    final record = await db.select(res: DBRecord(tableName, key));
    return record != null;
  }

  Future<void> delete(String key) async {
    await db.delete(res: DBRecord(tableName, key));
  }

  Future<void> clear() async {
    await db.delete(res: DBTable(tableName));
  }
}
