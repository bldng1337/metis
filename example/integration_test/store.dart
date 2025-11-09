import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';
import 'package:metis/store.dart';

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

void dotest() {
  test('Can use a store to store and retrieve data', () async {
    final db = AdapterSurrealDB(await SurrealDB.connect("mem://"));
    await db.use(ns: "test", db: "test");
    final store = KeyValueStore(db, "test");
    await store.set("test", "test");
    expect(await store.get("test"), "test");
    await store.delete("test");
    expect(await store.get("test"), null);
    await store.set("num", 10);
    expect(await store.get("num"), 10);
    await store.clear();
    expect(await store.contains("num"), false);
    expect(await store.get("num"), null);
  });
  // test('Can use a store to watch for changes', () async {
  //   final db = AdapterSurrealDB(await SurrealDB.connect("mem://"));
  //   await db.use(ns: "test", db: "test");
  //   final store = KeyValueStore(db, "test");

  //   final future = expectLater(
  //     store.watch("test"),
  //     emitsInOrder([
  //       null,
  //       "test",
  //       null,
  //       10,
  //     ]),
  //   );
  //   await Future.delayed(const Duration(seconds: 1));
  //   await store.set("test", "testa");
  //   await store.delete("test");
  //   await store.set("num", 10);
  //   await store.set("test", 10);
  //   db.dispose();
  //   print("finished");
  //   await future;
  //   print("finished2");
  // });
}
