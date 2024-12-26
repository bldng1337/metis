import 'package:flutter_surrealdb/flutter_surrealdb.dart';

abstract class Adapter {
  /// The database to use.
  final SurrealDB db;
  const Adapter({
    required this.db,
  });
  Future<void> init();
  Future<void> dispose();
}
