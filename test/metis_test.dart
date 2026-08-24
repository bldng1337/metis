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

  _MockSyncRepo({required this.pointData});

  @override
  Future<SyncRepoData> getSyncPointData() async => pointData;

  @override
  Stream<SyncData> querySyncData(int offset, int limit) async* {}

  @override
  Future<SyncData?> getSyncData(DBRecord id) async => null;

  @override
  Future<dynamic> pull(SyncData meta) async => null;

  @override
  Future<void> push(SyncData meta, dynamic data) async {}
}
