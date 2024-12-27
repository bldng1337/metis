import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/client.dart';
import 'package:metis/adapter/migration.dart';
import 'package:test/test.dart';

void main() {
  // setUpAll(() async => await RustLib.init());

  // TODO: Get Tests with Rust working outside of the surrealdb package

  // test('Counter value should be incremented', () async {
  //   await RustLib.init();
  //   final surreal = await AdapterSurrealDB.newMem();
  //   await surreal.setMigrationAdapter(
  //       version: 1,
  //       migrationName: "testdata",
  //       onMigrate: (db, from, to) async {
  //         print("Migrating from $from to $to");
  //       },
  //       onCreate: (db) async {
  //         await db.query(query: """
  //                     USE NS data;
  //                     USE DB site;

  //                     DEFINE TABLE users SCHEMAFULL;
  //                     DEFINE FIELD name ON TABLE users TYPE string;
  //                     DEFINE FIELD metadata ON TABLE users FLEXIBLE TYPE object;

  //                     DEFINE TABLE posts SCHEMAFULL;
  //                     DEFINE FIELD title ON TABLE posts TYPE string;
  //                     DEFINE FIELD body ON TABLE posts TYPE string;
  //                     DEFINE FIELD metadata ON TABLE posts FLEXIBLE TYPE object;
  //                     """);
  //       });
  //   expect(await surreal.getAdapter<MigrationAdapter>().getVersion(), 1);

  //   // expect(counter.value, 1);
  // });
}
