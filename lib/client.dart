import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';

class AdapterSurrealDB extends SurrealDB {
  final SurrealDB _surreal;
  final Map<(Type, String), Adapter> _adapters = {};

  AdapterSurrealDB(this._surreal);

  static Future<AdapterSurrealDB> newFile(String path) async {
    return AdapterSurrealDB(await SurrealDB.newFile(path));
  }

  static Future<AdapterSurrealDB> newMem() async {
    return AdapterSurrealDB(await SurrealDB.newMem());
  }

  Future<T> setAdapter<T extends Adapter>(T adapter, {String? name}) async {
    if (_adapters.containsKey((T, name ?? ""))) {
      await _adapters[(T, name ?? "")]!.dispose();
    }
    await adapter.init();
    _adapters[(T, name ?? "")] = adapter;
    return adapter;
  }

  T getAdapter<T extends Adapter>({String? name}) {
    return _adapters[(T, name ?? "")]! as T;
  }

  @override
  Future<void> export({required String path}) async {
    return _surreal.export(path: path);
  }

  @override
  Future<void> import({required String path}) async {
    return _surreal.import(path: path);
  }

  @override
  Future<dynamic> create({required Resource res}) async {
    return _surreal.create(res: res);
  }

  @override
  Future<void> delete({required Resource res}) async {
    return _surreal.delete(res: res);
  }

  @override
  Future<dynamic> select({required Resource res}) async {
    return _surreal.select(res: res);
  }

  @override
  Stream<DBNotification> watch({required Resource res}) {
    return _surreal.watch(res: res);
  }

  @override
  Future<dynamic> updateContent(
      {required Resource res, required dynamic data}) async {
    return _surreal.updateContent(res: res, data: data);
  }

  @override
  Future<dynamic> updateMerge(
      {required Resource res, required dynamic data}) async {
    return _surreal.updateMerge(res: res, data: data);
  }

  @override
  Future<dynamic> insert({required Resource res, required dynamic data}) async {
    return _surreal.insert(res: res, data: data);
  }

  @override
  Future<dynamic> upsert({required Resource res, required dynamic data}) async {
    return _surreal.upsert(res: res, data: data);
  }

  @override
  Future<List<dynamic>> query(
      {required String query, Map<String, dynamic>? vars}) async {
    return _surreal.query(query: query, vars: vars);
  }

  @override
  Future<dynamic> run({required String function, required dynamic args}) async {
    return _surreal.run(function: function, args: args);
  }

  @override
  Future<void> set({required String key, required dynamic value}) async {
    return _surreal.set(key: key, value: value);
  }

  @override
  Future<void> unset({required String key}) async {
    return _surreal.unset(key: key);
  }

  // AUTH

  @override
  Future<void> authenticate({required String token}) async {
    return _surreal.authenticate(token: token);
  }

  @override
  Future<String> signin(
      {required String namespace,
      required String database,
      required String access,
      required dynamic extra}) async {
    return _surreal.signin(
        namespace: namespace, database: database, access: access, extra: extra);
  }

  @override
  Future<String> signup(
      {required String namespace,
      required String database,
      required String access,
      required dynamic extra}) async {
    return _surreal.signup(
        namespace: namespace, database: database, access: access, extra: extra);
  }

  // SCOPING
  @override
  Future<void> useDb({required String db}) async {
    return _surreal.useDb(db: db);
  }

  @override
  Future<void> useNs({required String namespace}) async {
    return _surreal.useNs(namespace: namespace);
  }

  @override
  Future<void> use({String? db, String? namespace}) async {
    return _surreal.use(db: db, namespace: namespace);
  }

  // OTHER
  @override
  Future<String> version() async {
    return _surreal.version();
  }

  Future<void> disposeAdapters() async {
    for (final adapter in _adapters.values) {
      await adapter.dispose();
    }
    _adapters.clear();
  }

  @override
  void dispose() {
    disposeAdapters().then((_) {
      _surreal.dispose();
    });
  }

  @override
  bool get isDisposed {
    return _surreal.isDisposed;
  }

  @override
  SurrealProxy get rustbinding => _surreal.rustbinding;

  SurrealDB get inner => _surreal;
}
