import 'package:flutter_test/flutter_test.dart';
import 'package:metis/store.dart';

void main() {
  test('Can use a store to store and retrieve data', () async {
    final store = await KeyValueStore.newMem();
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
  test('Can use a store to watch for changes', () async {
    final store = await KeyValueStore.newMem();

    expectLater(
      store.watch("test"),
      emitsInOrder([
        null,
        "test",
        null,
        10,
      ]),
    );
    await Future.delayed(const Duration(milliseconds: 1000));

    await store.set("test", "test");
    await store.delete("test");
    await store.set("num", 10);
    await store.set("test", 10);
  });
}
