import 'package:flutter_test/flutter_test.dart';
import 'package:metis/metis.dart';
import 'package:metis/store.dart';

void main() {
  setUpAll(() async => await RustLib.init());
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
    final stream = store.watch("test");
    dynamic latest;
    stream.listen((event) {
      latest = event;
    });
    expect(latest, null);
    await store.set("test", "test");
    await Future.delayed(const Duration(milliseconds: 1));
    expect(latest, "test");
    await store.delete("test");
    await Future.delayed(const Duration(milliseconds: 1));
    expect(latest, null);
    await store.set("num", 10);
    await Future.delayed(const Duration(milliseconds: 1));
    expect(latest, null);
    await store.set("test", 10);
    await Future.delayed(const Duration(milliseconds: 1));
    expect(latest, 10);
  });
}
