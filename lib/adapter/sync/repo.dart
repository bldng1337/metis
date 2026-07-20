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

  SyncData.fromDB(Map<String, dynamic> db)
      : hlc = Hlc(db['timestamp'] as DateTime, db['count'] as int,
            base64.encode(utf8.encode(json.encode((db["id"] as DBRecord).id)))),
        deleted = db['deleted'],
        entry = db['entry'] as DBRecord,
        assert(db["id"] is DBRecord,
            "Wrong id type in DB, expected DBRecord but got ${db["id"].runtimeType}");

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
      };

  int compareTo(SyncData other) {
    return other.hlc.compareTo(hlc);
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
      table == other.table &&
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
      final repotable =
          remotedata.tables.where((e) => e.table == table.table).firstOrNull;
      if (repotable == null) continue;
      if (!table.match(repotable)) {
        throw VersionMismatchException(
            "Version mismatch with Repo on table ${table.table.resource}",
            table.version,
            repotable.version);
      }
    }
    await _syncdata(remote, remotedata.entries,
        chunkSize: chunkSize,
        onProgress: (progress, total) =>
            onProgress?.call(progress, remotedata.entries + localdata.entries));
    await remote._syncdata(this, localdata.entries,
        chunkSize: chunkSize,
        onProgress: (progress, total) => onProgress?.call(
            progress + remotedata.entries,
            remotedata.entries + localdata.entries));
  }

  Future<void> _syncdata(SyncRepo remote, int length,
      {int chunkSize = 50,
      void Function(int progress, int total)? onProgress}) async {
    for (int offset = 0; offset < length; offset += chunkSize) {
      onProgress?.call(offset, length);
      await for (final remotesync in remote.querySyncData(offset, chunkSize)) {
        final localsync = await getSyncData(remotesync.entry);
        if (localsync == null) {
          await push(remotesync, await remote.pull(remotesync));
          continue;
        }
        switch (localsync.compareTo(remotesync)) {
          case -1:
            await remote.push(localsync, await pull(localsync));
            break;
          case 0:
            break;
          case 1:
            await push(remotesync, await remote.pull(remotesync));
            break;
        }
      }
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

class SyncHttpClient extends SyncRepo {
  final String url;
  final HttpClient client;

  SyncHttpClient({
    required this.url,
    required this.client,
  });

  Future<String> _request(String path, Object? body) async {
    Uri uri = Uri.parse(url + path);
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

class SyncHttpServer {
  final int port;
  final SyncRepo repo;
  const SyncHttpServer({
    this.port = 9876,
    required this.repo,
  });

  Future<void> handle(HttpRequest req, String path) async {
    if (req.headers.contentType?.mimeType != ContentType.json.mimeType) {
      req.response
        ..statusCode = HttpStatus.badRequest
        ..write('{"error":"Content-Type must be application/json"}')
        ..close();
      return;
    }
    try {
      if (path == "/getSyncData") {
        final content = await utf8.decoder.bind(req).join();
        final data =
            jsonDecode(content, reviver: revive) as Map<String, dynamic>;
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
        final data =
            jsonDecode(content, reviver: revive) as Map<String, dynamic>;
        final syncData = SyncData.fromJson(data);
        final res = await repo.pull(syncData);
        req.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode(res, toEncodable: serializer))
          ..close();
      } else if (path == "/push") {
        final content = await utf8.decoder.bind(req).join();
        final data =
            jsonDecode(content, reviver: revive) as Map<String, dynamic>;
        final syncData = SyncData.fromJson(data['syncData']);
        await repo.push(syncData, data['data']);
        req.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
      } else if (path == "/querySyncData") {
        final content = await utf8.decoder.bind(req).join();
        final data =
            jsonDecode(content, reviver: revive) as Map<String, dynamic>;
        final offset = data['offset'] as int? ?? 0;
        final limit = data['limit'] as int? ?? 50;
        final res = await repo.querySyncData(offset, limit).toList();
        req.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode(res.map((e) => e.toJson()).toList(),
              toEncodable: serializer))
          ..close();
      } else {
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('{"error":"Not found"}')
          ..close();
      }
    } catch (e) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write(jsonEncode({'error': e.toString()}))
        ..close();
    }
  }

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    await for (final req in server) {
      await handle(req, req.requestedUri.path);
    }
  }
}
