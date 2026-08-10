import 'package:crdt/crdt.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';

/// Pure-logic unit tests for the sync layer that do not require the SurrealDB
/// native library. The end-to-end and fuzz scenarios live under `example/`
/// (which depends on the local metis package via a path dependency).
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
          hlc: Hlc(ts, 1, 'a'), deleted: false, entry: const DBRecord('t', 'r'));
      final b = SyncData(
          hlc: Hlc(ts, 2, 'a'), deleted: false, entry: const DBRecord('t', 'r'));
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(a), greaterThan(0));
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
      };
      final data = SyncData.fromDB(row);
      expect(data.deleted, isTrue);
      expect(data.entry, const DBRecord('t', 'r'));
      expect(data.hlc.counter, 3);
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
}
