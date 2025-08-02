import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';

class KeyValueStore {
  final SurrealDB db;
  final String tableName;
  KeyValueStore(this.db, this.tableName);

  static Future<KeyValueStore> newFile(String path) async {
    final db = await SurrealDB.newFile(path);
    await db.useDb(db: "keyvalue");
    await db.useNs(namespace: "keyvalue");
    return KeyValueStore(db, 'keyvalue');
  }

  static Future<KeyValueStore> newMem() async {
    final db = await SurrealDB.newMem();
    await db.useDb(db: "keyvalue");
    await db.useNs(namespace: "keyvalue");
    return KeyValueStore(db, 'keyvalue');
  }

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

  Stream<dynamic> watch(String key) {
    return db.watch(res: DBRecord(tableName, key)).map((event) {
      if (event.action == Action.delete) {
        return null;
      }
      return event.value?["value"];
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
