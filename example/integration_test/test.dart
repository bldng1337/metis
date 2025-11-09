import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';

import 'crdt.dart' as crdt;
import 'dataclass.dart' as dataclass;
import 'migration.dart' as migration;
import 'store.dart' as store;

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  group('CRDT', crdt.dotest);
  group('Dataclass', dataclass.dotest);
  group('Migration', migration.dotest);
  group('Store', store.dotest);
}
