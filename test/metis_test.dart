import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';

/// Pure-logic unit tests that do not require the SurrealDB native library.
/// The end-to-end and fuzz scenarios live under `example/` (which depends on
/// the local metis package via a path dependency).
void main() {
  group('SyncData.compareTo', () {
    SyncData make(DateTime ts, int count) => SyncData(
          hlc: Hlc(ts, count, 'node'),
          deleted: false,
          entry: const DBRecord('t', 'r'),
        );

    test('is negative when local is older (natural ordering)', () {
      final older = make(DateTime.utc(2024, 1, 1), 0);
      final newer = make(DateTime.utc(2024, 1, 2), 0);
      expect(older.compareTo(newer), lessThan(0));
      expect(newer.compareTo(older), greaterThan(0));
    });

    test('falls back to counter then node id on equal timestamps', () {
      final ts = DateTime.utc(2024, 1, 1);
      final a = SyncData(
          hlc: Hlc(ts, 1, 'a'),
          deleted: false,
          entry: const DBRecord('t', 'r'));
      final b = SyncData(
          hlc: Hlc(ts, 2, 'a'),
          deleted: false,
          entry: const DBRecord('t', 'r'));
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(a), greaterThan(0));

      final c = SyncData(
          hlc: Hlc(ts, 1, 'c'),
          deleted: false,
          entry: const DBRecord('t', 'r'));
      // Equal timestamp+counter: the node id breaks the tie deterministically.
      expect(a.compareTo(c), isNot(0));
      expect(c.compareTo(a), -a.compareTo(c));
    });

    test('is zero for equal HLCs', () {
      final a = make(DateTime.utc(2024, 1, 1), 5);
      final b = make(DateTime.utc(2024, 1, 1), 5);
      expect(a.compareTo(b), 0);
    });
  });

  group('SyncData.fromDB validation', () {
    test('throws a clear ArgumentError when id is not a DBRecord', () {
      // A row whose id came back as a plain String (e.g. a schema mismatch)
      // used to trigger an unhelpful TypeError in the initializer list before
      // the assert could report the real problem.
      final row = <String, dynamic>{
        'id': 'not-a-record',
        'timestamp': DateTime.utc(2024, 1, 1),
        'count': 0,
        'deleted': false,
        'entry': const DBRecord('t', 'r'),
      };
      expect(
        () => SyncData.fromDB(row),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('round-trips a well-formed row', () {
      final row = <String, dynamic>{
        'id': const DBRecord('crdt', ['t', 'r']),
        'timestamp': DateTime.utc(2024, 1, 1),
        'count': 3,
        'deleted': true,
        'entry': const DBRecord('t', 'r'),
        'node': '11111111-1111-4111-8111-111111111111',
      };
      final data = SyncData.fromDB(row);
      expect(data.deleted, isTrue);
      expect(data.entry, const DBRecord('t', 'r'));
      expect(data.hlc.counter, 3);
      expect(data.hlc.nodeId, '11111111-1111-4111-8111-111111111111');
      expect(data.toDB()['node'], data.hlc.nodeId);
    });

    test('reads the node id (v2 rows) and falls back on old rows', () {
      final base = <String, dynamic>{
        'id': const DBRecord('crdt', ['t', 'r']),
        'timestamp': DateTime.utc(2024, 1, 1),
        'count': 0,
        'deleted': false,
        'entry': const DBRecord('t', 'r'),
      };
      final withNode = SyncData.fromDB({
        ...base,
        'node': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      });
      expect(withNode.hlc.nodeId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      // Rows written before the node field existed keep comparing via the
      // old deterministic derivation.
      final withoutNode = SyncData.fromDB({...base});
      expect(withoutNode.hlc.nodeId, isNotEmpty);
      expect(withoutNode.hlc.nodeId, isNot(withNode.hlc.nodeId));
    });

    test('carries the node id through the JSON round trip', () {
      final data = SyncData(
        hlc: Hlc(DateTime.utc(2024, 5, 5), 7,
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
        deleted: false,
        entry: const DBRecord('t', 'r'),
      );
      final restored = SyncData.fromJson(data.toJson());
      expect(restored.hlc.nodeId, data.hlc.nodeId);
      expect(restored.hlc.counter, 7);
    });
  });

  group('SyncTable.match', () {
    const table = DBTable('notes');
    test('matches when versions fall in each others ranges', () {
      const a = SyncTable(
          table: table, version: 2, range: VersionRange(from: 1, to: 3));
      const b = SyncTable(
          table: table, version: 2, range: VersionRange(from: 1, to: 3));
      expect(a.match(b), isTrue);
    });

    test('does not match when a version is out of range', () {
      const a = SyncTable(
          table: table, version: 5, range: VersionRange(from: 1, to: 3));
      const b = SyncTable(
          table: table, version: 2, range: VersionRange(from: 1, to: 3));
      expect(a.match(b), isFalse);
    });
  });

  group('VersionRange.fromJson validation', () {
    test('parses a valid range', () {
      final range = VersionRange.fromJson({'from': 1, 'to': 4});
      expect(range.from, 1);
      expect(range.to, 4);
      expect(range.match(3), isTrue);
      expect(range.match(5), isFalse);
    });

    test('throws on non-int fields', () {
      expect(() => VersionRange.fromJson({'from': '1', 'to': 4}),
          throwsA(isA<ArgumentError>()));
      expect(() => VersionRange.fromJson({'from': 1, 'to': null}),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('syncUri', () {
    test('resolves paths against a bare host', () {
      expect(syncUri('http://localhost:1234', '/getSyncData').toString(),
          'http://localhost:1234/getSyncData');
    });

    test('preserves a base path', () {
      expect(
          syncUri('http://localhost:1234/api/sync', '/getSyncData').toString(),
          'http://localhost:1234/api/sync/getSyncData');
    });

    test('handles trailing slashes and doubled leading slashes', () {
      expect(syncUri('http://localhost:1234/api/', '/getSyncData').toString(),
          'http://localhost:1234/api/getSyncData');
      expect(syncUri('http://localhost:1234', '//pull').toString(),
          'http://localhost:1234/pull');
    });
  });

  group('SyncRepo.sync table negotiation', () {
    SyncTable table(String name) => SyncTable(
        table: DBTable(name), version: 1, range: const VersionRange.exact(1));

    test(
        'throws TableMismatchException when a local table is missing on remote',
        () async {
      final local = _MockSyncRepo(
        pointData: SyncRepoData(version: 1, entries: 0, tables: {table('a')}),
      );
      final remote = _MockSyncRepo(
        pointData: SyncRepoData(version: 1, entries: 0, tables: {table('b')}),
      );
      await expectLater(
          local.sync(remote), throwsA(isA<TableMismatchException>()));
    });

    test('allows the remote to sync a superset of tables', () async {
      final local = _MockSyncRepo(
        pointData: SyncRepoData(version: 1, entries: 0, tables: {table('a')}),
      );
      final remote = _MockSyncRepo(
        pointData: SyncRepoData(
            version: 1, entries: 0, tables: {table('a'), table('b')}),
      );
      await local.sync(remote); // must not throw
    });

    test('throws VersionMismatchException on differing repo versions',
        () async {
      final local = _MockSyncRepo(
        pointData: SyncRepoData(version: 1, entries: 0, tables: {table('a')}),
      );
      final remote = _MockSyncRepo(
        pointData: SyncRepoData(version: 2, entries: 0, tables: {table('a')}),
      );
      await expectLater(
          local.sync(remote), throwsA(isA<VersionMismatchException>()));
    });
  });

  group('SyncRepo.sync walker (keyset pagination)', () {
    SyncData row(String id, DateTime ts) => SyncData(
          hlc: Hlc(ts, 0, 'remote'),
          deleted: false,
          entry: DBRecord('t', id),
        );

    test('pages the remote with the last row as cursor, not offsets', () async {
      final base = DateTime.utc(2024, 1, 1);
      final remote = _PagingRepo([
        for (int i = 0; i < 5; i++) row('r$i', base.add(Duration(seconds: i))),
      ]);
      final local = _PagingRepo(<SyncData>[]);

      await local.sync(remote, chunkSize: 2);

      // 5 rows in pages of 2: three data pages plus the empty page that
      // ends the walk; each page starts after the previous page's last row.
      expect(remote.requestedCursors, [
        null,
        const DBRecord('t', 'r1'),
        const DBRecord('t', 'r3'),
        const DBRecord('t', 'r4'),
      ]);
      expect(local.pushed.map((e) => e.$1.entry.id), hasLength(5));
    });

    test('a concurrent insert before the cursor cannot skip existing rows',
        () async {
      // With offsets, an insert that sorts before the read position shifts
      // rows past the offset and the next page skips one. With a cursor the
      // next page is anchored to the last seen row, so nothing is skipped.
      final base = DateTime.utc(2024, 1, 1);
      final rows = [
        for (int i = 0; i < 4; i++) row('r$i', base.add(Duration(seconds: i))),
      ];
      final remote = _PagingRepo(rows);
      final local = _PagingRepo(<SyncData>[]);
      remote.onAfterPage = (page) {
        if (remote.requestedCursors.length == 1) {
          // inserts before the walk's current position, like a concurrent
          // sync pushing rows into the walked table
          rows.insert(
              0, row('inserted0', base.add(const Duration(minutes: 1))));
          rows.insert(
              1, row('inserted1', base.add(const Duration(minutes: 2))));
        }
      };

      await local.sync(remote, chunkSize: 2);

      expect(local.pushed.map((e) => e.$1.entry.id),
          containsAll(['r0', 'r1', 'r2', 'r3']));
    });

    test('local-newer rows are pushed to the remote after the walk', () async {
      final base = DateTime.utc(2024, 1, 1);
      final remote = _PagingRepo([row('r0', base), row('r1', base)]);
      final local = _PagingRepo([
        SyncData(
          hlc: Hlc(base.add(const Duration(hours: 1)), 0, 'local'),
          deleted: false,
          entry: const DBRecord('t', 'mine'),
        ),
      ]);

      await local.sync(remote, chunkSize: 50);

      expect(remote.pushed.map((e) => e.$1.entry.id), ['mine']);
      expect(local.pushed.map((e) => e.$1.entry.id), isNot(contains('mine')));
    });
  });

  group('SyncRepo.syncRecord', () {
    const entry = DBRecord('t', 'r');
    SyncData meta(DateTime ts, int count, String node) => SyncData(
          hlc: Hlc(ts, count, node),
          deleted: false,
          entry: entry,
        );

    test('pushes local to remote when local is newer', () async {
      final local = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 2), 0, 'a'),
        },
      );
      final remote = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 0, 'b'),
        },
      );
      expect(await local.syncRecord(remote, entry), isTrue);
      expect(remote.pushed, hasLength(1));
      expect(remote.pushed.single.$1.hlc, local.records[entry]!.hlc);
      expect(remote.pushed.single.$2, 'data-of-r');
      expect(local.pushed, isEmpty);
    });

    test('pulls remote into local when remote is newer', () async {
      final local = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 0, 'a'),
        },
      );
      final remote = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 2), 0, 'b'),
        },
      );
      expect(await local.syncRecord(remote, entry), isTrue);
      expect(local.pushed, hasLength(1));
      expect(local.pushed.single.$1.hlc, remote.records[entry]!.hlc);
      expect(local.pushed.single.$2, 'data-of-r');
      expect(remote.pushed, isEmpty);
    });

    test('does nothing when both sides agree', () async {
      final local = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 3, 'a'),
        },
      );
      final remote = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 3, 'a'),
        },
      );
      expect(await local.syncRecord(remote, entry), isFalse);
      expect(local.pushed, isEmpty);
      expect(remote.pushed, isEmpty);
    });

    test('handles records that exist on only one side', () async {
      final local = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 0, 'a'),
        },
      );
      final remote = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 0, tables: {}),
      );
      expect(await local.syncRecord(remote, entry), isTrue);
      expect(remote.pushed, hasLength(1));
      expect(remote.pushed.single.$1.hlc, local.records[entry]!.hlc);

      final remoteOnly = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 1, tables: {}),
        records: {
          entry: meta(DateTime.utc(2024, 1, 1), 0, 'b'),
        },
      );
      final emptyLocal = _MockSyncRepo(
        pointData: const SyncRepoData(version: 1, entries: 0, tables: {}),
      );
      expect(await emptyLocal.syncRecord(remoteOnly, entry), isTrue);
      expect(emptyLocal.pushed, hasLength(1));
      expect(emptyLocal.pushed.single.$1.hlc, remoteOnly.records[entry]!.hlc);
    });
  });

  group('DBChange', () {
    test('carries the database diff ops verbatim', () {
      const ops = [
        {'op': 'replace', 'path': '/value', 'value': 2}
      ];
      const change = DBChange(patch: ops);
      expect(change.patch, same(ops));
      expect(change.deleted, isFalse);
      expect(change.patch, isNotEmpty);
    });

    test('deletes carry an empty patch', () {
      const change = DBChange(deleted: true);
      expect(change.patch, isEmpty);
      expect(change.deleted, isTrue);
    });
  });
}

/// Minimal in-memory [SyncRepo] for logic tests.
class _MockSyncRepo extends SyncRepo {
  final SyncRepoData pointData;
  final Map<DBRecord, SyncData> records;
  final List<(SyncData, dynamic)> pushed = [];

  _MockSyncRepo({required this.pointData, this.records = const {}});

  @override
  Future<SyncRepoData> getSyncPointData() async => pointData;

  @override
  Stream<SyncData> querySyncData(DBRecord? after, int limit) async* {}

  @override
  Future<SyncData?> getSyncData(DBRecord id) async => records[id];

  @override
  Future<dynamic> pull(SyncData meta) async => 'data-of-${meta.entry.id}';

  @override
  Future<void> push(SyncData meta, dynamic data) async =>
      pushed.add((meta, data));
}

/// A [SyncRepo] whose CRDT rows are an explicit ordered list, so tests can
/// observe (and mutate mid-walk) what the sync walker pages over.
class _PagingRepo extends SyncRepo {
  final List<SyncData> rows;
  final List<DBRecord?> requestedCursors = [];
  final List<(SyncData, dynamic)> pushed = [];
  final Set<SyncTable> tables;

  /// Invoked after each page is materialized, before it is handed to the
  /// walker; lets a test mutate [rows] like a concurrent writer would.
  void Function(List<SyncData> page)? onAfterPage;

  _PagingRepo(this.rows, {Set<SyncTable>? tables})
      : tables = tables ??
            {
              const SyncTable(
                  table: DBTable('t'),
                  version: 1,
                  range: VersionRange.exact(1)),
            };

  @override
  Future<SyncRepoData> getSyncPointData() async =>
      SyncRepoData(version: 1, entries: rows.length, tables: tables);

  @override
  Stream<SyncData> querySyncData(DBRecord? after, int limit) async* {
    int start = 0;
    if (after != null) {
      start = rows.indexWhere((r) => r.entry == after) + 1;
    }
    final page = <SyncData>[];
    for (int i = start; i < rows.length && page.length < limit; i++) {
      page.add(rows[i]);
    }
    requestedCursors.add(after);
    onAfterPage?.call(page);
    yield* Stream.fromIterable(page);
  }

  @override
  Future<SyncData?> getSyncData(DBRecord id) async {
    for (final r in rows) {
      if (r.entry == id) return r;
    }
    return null;
  }

  @override
  Future<dynamic> pull(SyncData meta) async => {'v': meta.entry.id};

  @override
  Future<void> push(SyncData meta, dynamic data) async {
    rows.add(meta);
    pushed.add((meta, data));
  }
}
