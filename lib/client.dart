import 'dart:async';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:uuid/uuid_value.dart';

class AdapterSurrealDB implements SurrealDB {
  final SurrealDB _surreal;
  final Map<(Type, String), Adapter> _adapters = {};

  AdapterSurrealDB(this._surreal);

  static Future<AdapterSurrealDB> connect(String endpoint,
      {Options? opts}) async {
    final surreal = await SurrealDB.connect(endpoint, opts: opts);
    return AdapterSurrealDB(surreal);
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
  Future<String> export({Config? options}) {
    return _surreal.export(options: options);
  }

  @override
  Future<void> import({required String data}) async {
    return _surreal.import(data: data);
  }

  @override
  Future<dynamic> create(Resource res, dynamic data,
      {bool? only,
      Output? output,
      Duration? timeout,
      DateTime? version}) async {
    return _surreal.create(res, data,
        only: only, output: output, timeout: timeout, version: version);
  }

  @override
  Future<void> delete(Resource thing,
      {bool? only, Output? output, Duration? timeout}) async {
    return _surreal.delete(thing, only: only, output: output, timeout: timeout);
  }

  @override
  Future<dynamic> select(Resource thing) async {
    return _surreal.select(thing);
  }

  @override
  Stream<Notification> live(DBTable table, {bool? diff}) {
    return _surreal.live(table);
  }

  @override
  Future<List<dynamic>> insert(
    DBTable thing,
    dynamic data, {
    InsertDataExpr? dataExpr,
    bool? relation,
    Output? output,
    Duration? timeout,
    DateTime? version,
    Map<String, dynamic>? vars,
  }) async {
    return _surreal.insert(thing, data,
        dataExpr: dataExpr,
        relation: relation,
        output: output,
        timeout: timeout,
        version: version,
        vars: vars);
  }

  @override
  Future<dynamic> upsert(Resource thing, dynamic data) async {
    return _surreal.upsert(thing, data);
  }

  @override
  Future<List<dynamic>> query(
    String query, {
    Map<String, dynamic>? vars,
    bool throwOnError = true,
  }) async {
    return (await _surreal.query(query, vars: vars, throwOnError: throwOnError))
        as List<dynamic>;
  }

  @override
  Future<dynamic> run(String function,
      {List<dynamic>? args, String? version}) async {
    return _surreal.run(function, args: args, version: version);
  }

  // AUTH

  @override
  Future<void> use({String? db, String? ns}) async {
    return _surreal.use(db: db, ns: ns);
  }

  // OTHER
  @override
  Future<String> version() async {
    return (await _surreal.version()) as String;
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

  SurrealDB get inner => _surreal;

  @override
  Future<String> engineVersion() {
    return _surreal.engineVersion();
  }

  @override
  Future info() {
    return _surreal.info();
  }

  @override
  Future<void> kill(UuidValue id) {
    return _surreal.kill(id);
  }

  @override
  Stream<Notification> liveOf(
    UuidValue id, {
    Future<void> Function()? onKill,
    bool shouldKillOnCancel = true,
  }) {
    return _surreal.liveOf(id,
        onKill: onKill, shouldKillOnCancel: shouldKillOnCancel);
  }

  @override
  Future update(Resource thing, data,
      {DataExpr? dataExpr,
      bool? only,
      String? condition,
      Output? output,
      Duration? timeout,
      Map<String, dynamic>? vars}) {
    return _surreal.update(thing, data,
        dataExpr: dataExpr,
        only: only,
        condition: condition,
        output: output,
        timeout: timeout,
        vars: vars);
  }

  @override
  Future<void> authenticate(String token) {
    return _surreal.authenticate(token);
  }

  @override
  Future<void> invalidate() {
    return _surreal.invalidate();
  }

  @override
  Future<void> set(String key, value) {
    return _surreal.set(key, value);
  }

  @override
  Future<dynamic> signin(
      {String? ns,
      String? db,
      String? username,
      String? password,
      String? access,
      required variables}) {
    return _surreal.signin(
        ns: ns,
        db: db,
        username: username,
        password: password,
        access: access,
        variables: variables);
  }

  @override
  Future<dynamic> signup(
      {required String ns,
      required String db,
      required String access,
      required variables}) {
    return _surreal.signup(
        ns: ns, db: db, access: access, variables: variables);
  }

  @override
  Future<void> unset(String name) {
    return _surreal.unset(name);
  }
}
