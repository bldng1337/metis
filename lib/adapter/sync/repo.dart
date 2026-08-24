import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter/migration.dart';
import 'package:uuid/uuid_value.dart';

/// Tag used to mark SurrealDB native types in the JSON sync payload so the
/// revive function can reconstruct them.
const _metisCrdtTag = '__metis_crdt__';

class SyncData {
  Hlc hlc;
  DBRecord entry;
  bool deleted;

  SyncData({
    required this.hlc,
    required this.deleted,
    required this.entry,
  });

  factory SyncData.fromDB(Map<String, dynamic> db) {
    final id = db['id'];
    if (id is! DBRecord) {
      throw ArgumentError(
          'Wrong id type in DB, expected DBRecord but got ${id.runtimeType}');
    }
    return SyncData(
      hlc: Hlc(
          db['timestamp'] as DateTime,
          db['count'] as int,
          // Rows written before the node field existed keep their old
          // deterministic node so HLCs written by them still compare.
          (db['node'] as String?) ??
              base64.encode(utf8.encode(json.encode(id.id)))),
      deleted: db['deleted'] as bool,
      entry: db['entry'] as DBRecord,
    );
  }

  SyncData.fromJson(Map<String, dynamic> json)
      : hlc = Hlc.parse(json['hlc']),
        deleted = json['deleted'],
        entry = json['entry'] is DBRecord
            ? json['entry']
            : DBRecord.fromJson(json['entry']);

  Map<String, dynamic> toJson() => {
        'hlc': hlc.toString(),
        'deleted': deleted,
        'entry': entry.toJson(),
      };

  Map<String, dynamic> toDB() => {
        'timestamp': hlc.dateTime,
        'count': hlc.counter,
        'deleted': deleted,
        'entry': entry,
        'node': hlc.nodeId,
      };

  int compareTo(SyncData other) {
    return hlc.compareTo(other.hlc);
  }

  @override
  String toString() {
    return "SyncData($entry, $deleted, $hlc)";
  }
}

class SyncTable {
  final DBTable table;
  final int version;
  final VersionRange range;

  const SyncTable({
    required this.table,
    required this.version,
    required this.range,
  });

  SyncTable.fromJson(Map<String, dynamic> json)
      : table = json['table'] is String
            ? DBTable(json['table'])
            : DBTable.fromJson(json['table'] as Map<String, dynamic>),
        version = json['version'],
        range = VersionRange.fromJson(json['range']);

  Map<String, dynamic> toJson() => {
        'table': table.toJson(),
        'version': version,
        'range': range.toJson(),
      };
  bool match(SyncTable other) =>
      table.tb == other.table.tb &&
      range.match(other.version) &&
      other.range.match(version);
}

class SyncRepoData {
  final Set<SyncTable> tables;
  final int version;
  final int entries;

  const SyncRepoData({
    required this.tables,
    required this.version,
    required this.entries,
  });

  SyncRepoData.fromJson(Map<String, dynamic> json)
      : version = json['version'],
        entries = json['entries'],
        tables = (json['tables'] as List<dynamic>? ?? [])
            .map((e) => SyncTable.fromJson(e as Map<String, dynamic>))
            .toSet();
  Map<String, dynamic> toJson() => {
        'version': version,
        'entries': entries,
        'tables': tables.map((e) => e.toJson()).toList(),
      };
}

class TableMismatchException implements Exception {
  final String what;
  final DBTable table;

  const TableMismatchException(this.what, this.table);

  @override
  String toString() => "TableMismatchException: $what (${table.resource})";
}

abstract class SyncRepo {
  Future<SyncRepoData> getSyncPointData();

  Stream<SyncData> querySyncData(int offset, int limit);

  Future<SyncData?> getSyncData(DBRecord id);

  Future<dynamic> pull(SyncData meta);

  Future<void> push(SyncData meta, dynamic data);

  Future<void> sync(SyncRepo remote,
      {int chunkSize = 50,
      void Function(int progress, int total)? onProgress}) async {
    final localdata = await getSyncPointData();
    final remotedata = await remote.getSyncPointData();
    if (localdata.version != remotedata.version) {
      throw VersionMismatchException("Version mismatch with Repo, Repo",
          localdata.version, remotedata.version);
    }
    for (final table in localdata.tables) {
      final repotable = remotedata.tables
          .where((e) => e.table.tb == table.table.tb)
          .firstOrNull;
      if (repotable == null) {
        throw TableMismatchException(
            'Table is synced locally but missing on the remote repo',
            table.table);
      }
      if (!table.match(repotable)) {
        throw VersionMismatchException(
            "Version mismatch with Repo on table ${table.table.resource}",
            table.version,
            repotable.version);
      }
    }
    await _syncdata(remote, remotedata.entries,
        syncTables: localdata.tables.map((e) => e.table.tb).toSet(),
        chunkSize: chunkSize,
        onProgress: (progress, total) =>
            onProgress?.call(progress, remotedata.entries + localdata.entries));
    await remote._syncdata(this, localdata.entries,
        syncTables: remotedata.tables.map((e) => e.table.tb).toSet(),
        chunkSize: chunkSize,
        onProgress: (progress, total) => onProgress?.call(
            progress + remotedata.entries,
            remotedata.entries + localdata.entries));
  }

  Future<void> _syncdata(SyncRepo remote, int length,
      {Set<String>? syncTables,
      int chunkSize = 50,
      void Function(int progress, int total)? onProgress}) async {
    final deferred = <(SyncData, dynamic)>[];
    int offset = 0;
    while (true) {
      onProgress?.call(offset, length);
      final page = await remote.querySyncData(offset, chunkSize).toList();
      if (page.isEmpty) break;
      offset += page.length;
      for (final remotesync in page) {
        if (syncTables != null && !syncTables.contains(remotesync.entry.tb)) {
          continue;
        }
        final localsync = await getSyncData(remotesync.entry);
        if (localsync == null) {
          await push(remotesync, await remote.pull(remotesync));
          continue;
        }
        switch (localsync.compareTo(remotesync)) {
          // local Hlc is older -> remote wins, push remote data to local.
          case -1:
            await push(remotesync, await remote.pull(remotesync));
            break;
          case 0:
            break;
          // local Hlc is newer -> local wins, push local data to remote.
          case 1:
            deferred.add((localsync, await pull(localsync)));
            break;
        }
      }
    }
    for (final (meta, data) in deferred) {
      await remote.push(meta, data);
    }
  }
}

class VersionMismatchException implements Exception {
  final String what;
  final int local;
  final int remote;

  const VersionMismatchException(this.what, this.local, this.remote);

  @override
  String toString() {
    return "VersionMismatchException: $what local: $local remote: $remote";
  }
}

Uri syncUri(String url, String path) {
  final base = url.endsWith('/') ? url : '$url/';
  return Uri.parse(base).resolve(path.replaceFirst(RegExp(r'^/+'), ''));
}

class SyncHttpClient extends SyncRepo {
  final String url;
  final HttpClient client;

  SyncHttpClient({
    required this.url,
    required this.client,
  });

  Future<String> _request(String path, Object? body) async {
    final uri = syncUri(url, path);
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body, toEncodable: serializer));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final error = await utf8.decoder.bind(response).join();
      throw HttpException(
          'Request failed with status: ${response.statusCode}, error: $error');
    }
    return await utf8.decoder.bind(response).join();
  }

  @override
  Future<SyncData?> getSyncData(DBRecord id) async {
    final content = await _request('/getSyncData', id.toJson());
    final decoded = jsonDecode(content, reviver: revive);
    if (decoded == null) return null;
    return SyncData.fromJson(decoded as Map<String, dynamic>);
  }

  @override
  Future<SyncRepoData> getSyncPointData() async {
    final content = await _request('/getSyncPointData', {});
    return SyncRepoData.fromJson(jsonDecode(content, reviver: revive));
  }

  @override
  Future<dynamic> pull(SyncData meta) async {
    final content = await _request('/pull', meta.toJson());
    return jsonDecode(content, reviver: revive);
  }

  @override
  Future<void> push(SyncData meta, data) async {
    await _request('/push', {
      'syncData': meta.toJson(),
      'data': data,
    });
  }

  @override
  Stream<SyncData> querySyncData(int offset, int limit) async* {
    final content = await _request('/querySyncData', {
      'offset': offset,
      'limit': limit,
    });
    final list = jsonDecode(content, reviver: revive) as List<dynamic>;
    for (final e in list) {
      yield SyncData.fromJson(e as Map<String, dynamic>);
    }
  }

  void dispose() {
    client.close();
  }
}

Object? serializer(Object? obj) {
  if (obj == null) {
    return null;
  }
  if (obj is DBRecord) {
    return {...obj.toJson(), _metisCrdtTag: 'DBRecord'};
  }
  if (obj is DateTime) {
    return {_metisCrdtTag: 'DateTime', 'value': obj.toUtc().toIso8601String()};
  }
  if (obj is Duration) {
    return {_metisCrdtTag: 'Duration', 'value': obj.inMicroseconds};
  }
  if (obj is UuidValue) {
    return {_metisCrdtTag: 'Uuid', 'value': obj.uuid};
  }
  if (obj is BigInt) {
    return {_metisCrdtTag: 'BigInt', 'value': obj.toString()};
  }
  // NOTE: Uint8List is intentionally not tagged here. dart:converts jsonEncode already encodes a Uint8List as a JSON array (it never invokes toEncodable for it), so callers receive a List<int> on the other side. Consumers that need a Uint8List must convert it.
  try {
    return (obj as dynamic).toDBJson();
  } on NoSuchMethodError {
    // ignore: avoid_catching_errors
  }
  try {
    return (obj as dynamic).toJson();
  } on NoSuchMethodError {
    // ignore: avoid_catching_errors
  }
  throw Exception("Object of type ${obj.runtimeType} is not JSON serializable");
}

Object? revive(Object? key, Object? obj) {
  if (obj is Map<String, dynamic> && obj[_metisCrdtTag] is String) {
    switch (obj[_metisCrdtTag]) {
      case 'DBRecord':
        return DBRecord.fromJson(obj);
      case 'DateTime':
        return DateTime.parse(obj['value'] as String);
      case 'Duration':
        return Duration(microseconds: obj['value'] as int);
      case 'Uuid':
        return UuidValue.fromString(obj['value'] as String);
      case 'BigInt':
        return BigInt.parse(obj['value'] as String);
    }
  }
  return obj;
}

class SyncHttpException implements Exception {
  final int statusCode;
  final String message;

  const SyncHttpException(this.statusCode, this.message);

  @override
  String toString() => 'SyncHttpException($statusCode): $message';
}

class SyncHttpHandler {
  final SyncRepo repo;

  SyncHttpHandler({
    required this.repo,
  });

  Future<void> handle(HttpRequest req, String path) async {
    if (req.headers.contentType?.mimeType != ContentType.json.mimeType) {
      throw const SyncHttpException(
          HttpStatus.badRequest, 'Content-Type must be application/json');
    }
    if (path == "/getSyncData") {
      final content = await utf8.decoder.bind(req).join();
      final data = jsonDecode(content, reviver: revive) as Map<String, dynamic>;
      final syncData = DBRecord.fromJson(data);
      final res = await repo.getSyncData(syncData);
      req.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(res?.toJson(), toEncodable: serializer))
        ..close();
    } else if (path == "/getSyncPointData") {
      final res = await repo.getSyncPointData();
      req.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(res.toJson(), toEncodable: serializer))
        ..close();
    } else if (path == "/pull") {
      final content = await utf8.decoder.bind(req).join();
      final data = jsonDecode(content, reviver: revive) as Map<String, dynamic>;
      final syncData = SyncData.fromJson(data);
      final res = await repo.pull(syncData);
      req.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(res, toEncodable: serializer))
        ..close();
    } else if (path == "/push") {
      final content = await utf8.decoder.bind(req).join();
      final data = jsonDecode(content, reviver: revive) as Map<String, dynamic>;
      final syncData = SyncData.fromJson(data['syncData']);
      await repo.push(syncData, data['data']);
      req.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode({'status': 'ok'}))
        ..close();
    } else if (path == "/querySyncData") {
      final content = await utf8.decoder.bind(req).join();
      final data = jsonDecode(content, reviver: revive) as Map<String, dynamic>;
      final offset = data['offset'] as int? ?? 0;
      final limit = data['limit'] as int? ?? 50;
      final res = await repo.querySyncData(offset, limit).toList();
      req.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(res.map((e) => e.toJson()).toList(),
            toEncodable: serializer))
        ..close();
    } else {
      throw const SyncHttpException(HttpStatus.notFound, 'Not found');
    }
  }
}

class SyncHttpServer {
  final int port;
  final InternetAddress address;
  final SyncRepo repo;
  final SyncHttpHandler handler;

  SyncHttpServer({
    this.port = 9876,
    InternetAddress? address,
    required this.repo,
  })  : address = address ?? InternetAddress.loopbackIPv4,
        handler = SyncHttpHandler(repo: repo);

  Future<void> _serve(HttpRequest req) async {
    try {
      await handler.handle(req, req.requestedUri.path);
    } on SyncHttpException catch (e) {
      req.response
        ..statusCode = e.statusCode
        ..write(jsonEncode({'error': e.message}))
        ..close();
    } catch (e, s) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{"error":"Internal server error"}')
        ..close();
      Zone.current.handleUncaughtError(e, s);
    }
  }

  Future<void> start() async {
    final server = await HttpServer.bind(address, port);
    final done = Completer<void>();
    server.listen(
      (req) => _serve(req),
      onDone: done.complete,
      onError: (Object e, StackTrace s) => done.completeError(e, s),
    );
    await done.future;
  }
}
