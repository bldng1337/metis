import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter.dart';
import 'package:uuid/uuid_value.dart';

class AdapterSurrealDB implements SurrealDB {
  final SurrealDB _surreal;
  final Map<(Type, String), Adapter> _adapters = {};

  AdapterSurrealDB(this._surreal);

  /// [shareTag] attaches to (or creates) the process-wide shared connection
  /// registered under that tag, so additional connects — including from
  /// other isolates — reuse the same engine instead of reopening the
  /// database file. See [SurrealDB.connect].
  static Future<AdapterSurrealDB> connect(String endpoint,
      {Options? opts, String? shareTag}) async {
    final surreal =
        await SurrealDB.connect(endpoint, opts: opts, shareTag: shareTag);
    return AdapterSurrealDB(surreal);
  }

  Future<T> setAdapter<T extends Adapter>(T adapter, {String? name}) async {
    final key = (T, name ?? "");
    await adapter.init();
    final old = _adapters[key];
    _adapters[key] = adapter;
    await old?.dispose();
    return adapter;
  }

  T getAdapter<T extends Adapter>({String? name}) {
    final adapter = _adapters[(T, name ?? "")];
    if (adapter == null) {
      throw StateError(
          'Adapter $T (name: ${name ?? "default"}) is not registered');
    }
    return adapter as T;
  }

  @override
  Future<String> export({Config? options}) {
    return _surreal.export(options: options);
  }

  @override
  Stream<Uint8List> exportStream({Config? options}) {
    return _surreal.exportStream(options: options);
  }

  @override
  Future<void> import({required String data}) async {
    return _surreal.import(data: data);
  }

  @override
  Future<dynamic> create(Resource res, dynamic data) async {
    return _surreal.create(res, data);
  }

  @override
  Future<void> delete(Resource thing) async {
    return _surreal.delete(thing);
  }

  @override
  Future<dynamic> select(Resource thing) async {
    return _surreal.select(thing);
  }

  @override
  Stream<Notification> live(DBTable table, {bool? diff, UuidValue? session}) {
    return _surreal.live(table, diff: diff, session: session);
  }

  @override
  Future<List<dynamic>> insert(DBTable thing, dynamic data) async {
    return _surreal.insert(thing, data);
  }

  @override
  Future<dynamic> insertRelation(DBTable table, dynamic data) async {
    return _surreal.insertRelation(table, data);
  }

  @override
  Future<dynamic> merge(Resource thing, dynamic data) {
    return _surreal.merge(thing, data);
  }

  @override
  Future<dynamic> patch(Resource thing, List<Map<String, dynamic>> patches,
      {bool? diff}) {
    return _surreal.patch(thing, patches, diff: diff);
  }

  @override
  Future<dynamic> relate(
      Resource inRecord, String relation, Resource outRecord,
      {dynamic data}) {
    return _surreal.relate(inRecord, relation, outRecord, data: data);
  }

  @override
  Future<dynamic> upsert(Resource thing, dynamic data) async {
    return _surreal.upsert(thing, data);
  }

  @override
  Future<List<dynamic>> query(
    String query, {
    Map<String, dynamic>? vars,
  }) async {
    return (await _surreal.query(query, vars: vars)) as List<dynamic>;
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
  Future<void> dispose() async {
    await disposeAdapters();
    await _surreal.dispose();
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
  Future<void> kill(UuidValue id, {UuidValue? session}) {
    return _surreal.kill(id, session: session);
  }

  @override
  Stream<Notification> liveOf(
    UuidValue id, {
    Future<void> Function()? onKill,
    bool shouldKillOnCancel = true,
    UuidValue? session,
  }) {
    return _surreal.liveOf(id,
        onKill: onKill,
        shouldKillOnCancel: shouldKillOnCancel,
        session: session);
  }

  @override
  Future update(Resource thing, data) {
    return _surreal.update(thing, data);
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
      Map<String, dynamic>? variables}) {
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
      Map<String, dynamic>? variables}) {
    return _surreal.signup(
        ns: ns, db: db, access: access, variables: variables);
  }

  @override
  Future<void> unset(String name) {
    return _surreal.unset(name);
  }

    @override
    Future<SurrealTransaction> beginTransaction() {
      return _surreal.beginTransaction();
    }

    @override
    Future<T> transaction<T>(Future<T> Function(SurrealTransaction txn) body) async {
      return await _surreal.transaction(body);
    }
}
