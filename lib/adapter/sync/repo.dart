import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter/migration.dart';

class SyncData {
  Hlc hlc;
  DBRecord entry;
  bool deleted;

  SyncData({
    required this.hlc,
    required this.deleted,
    required this.entry,
  });

  SyncData.fromJson(Map<String, dynamic> json)
      : hlc = Hlc.parse(json['hlc']),
        deleted = json['deleted'],
        entry = json['entry'] is DBRecord
            ? json['entry']
            : DBRecord.fromJson(json['entry']);

  Map<String, dynamic> toJson() => {
        'hlc': hlc.toString(),
        'deleted': deleted,
        'entry': entry,
      };

  int compareTo(SyncData other) {
    return other.hlc.compareTo(hlc);
  }

  @override
  String toString() {
    return "SyncData $entry $deleted $hlc";
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
      : table = DBTable(json['table']),
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
        tables = json['tables'].map((e) => SyncTable.fromJson(e)).toSet();

  Map<String, dynamic> toJson() => {
        'version': version,
        'entries': entries,
        'tables': tables.map((e) => e.toJson()).toList(),
      };
}

abstract class SyncRepo {
  Future<SyncRepoData> getSyncPointData();

  Stream<SyncData> querySyncData(int from, int to);

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
      await for (final remotesync in remote.querySyncData(offset, chunkSize)) {
        onProgress?.call(offset, length);
        final localsync = await getSyncData(remotesync.entry);
        if (localsync == null) {
          await push(remotesync, await remote.pull(remotesync));
          continue;
        }
        switch (localsync.compareTo(remotesync)) {
          case -1:
            await remote.push(remotesync, await pull(remotesync));
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
