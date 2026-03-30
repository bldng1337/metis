import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';

import 'crdt.dart' as crdt;
import 'dataclass.dart' as dataclass;
import 'migration.dart' as migration;
import 'store.dart' as store;
import 'sync_http.dart' as sync_http;

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  group('CRDT', crdt.dotest);
  group('Dataclass', dataclass.dotest);
  group('Migration', migration.dotest);
  group('Store', store.dotest);
  group('SyncHttp', sync_http.dotest);
}
