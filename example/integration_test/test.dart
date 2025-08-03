import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';

import 'crdt.dart' as crdt;
import 'dataclass.dart' as dataclass;
import 'migration.dart' as migration;
import 'store.dart' as store;

void main() {
  setUpAll(() async => await RustLib.init());
  group('CRDT', crdt.main);
  group('Dataclass', dataclass.main);
  group('Migration', migration.main);
  group('Store', store.main);
}
