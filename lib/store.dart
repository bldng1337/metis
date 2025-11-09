import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';

class KeyValueStore {
  final SurrealDB db;
  final String tableName;
  KeyValueStore(this.db, this.tableName);

  Future<void> set(String key, dynamic value) async {
    await db.upsert(
      DBRecord(tableName, key),
      {"value": value},
    );
  }

  Future<dynamic> get(String key) async {
    final record = await db.select(DBRecord(tableName, key));
    return record?["value"];
  }

  // Stream<dynamic> watch(String key) async* {
  //   yield await get(key);
  //   final id = await db.query("LIVE SELECT * FROM \$table WHERE key = \$key",
  //       vars: {"key": key, "table": DBTable(tableName)});
  //   yield* db.liveOf(id[0]).map((event) {
  //     if (event.action == Action.delete) {
  //       return null;
  //     }
  //     return event.result?["value"];
  //   });
  // }

  Future<bool> contains(String key) async {
    final record = await db.select(DBRecord(tableName, key));
    return record != null;
  }

  Future<void> delete(String key) async {
    await db.delete(DBRecord(tableName, key));
  }

  Future<void> clear() async {
    await db.delete(DBTable(tableName));
  }
}
