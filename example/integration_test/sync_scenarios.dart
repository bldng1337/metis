import 'package:crdt/crdt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

/// Targeted regression scenarios for the sync bugs seen in the wild:
/// - one device empty, the other full -> the empty one must fill COMPLETELY
///   and the full one must keep everything;
/// - both devices initiating a sync at the same time (dion's autoSync is on
///   by default on both sides, so this is the norm, not the exception);
/// - "Clear Database" on one device must not wipe the peer;
/// - a late duplicate push must not overwrite newer data.
///
/// The randomized versions of these scenarios live in fuzz_sync.dart.
void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

const _table = DBTable('test');
const _tables = {
  SyncTable(table: _table, version: 1, range: VersionRange.exact(1)),
};

Future<({AdapterSurrealDB db, CrdtAdapter crdt})> _newDb() async {
  final db = await AdapterSurrealDB.connect('mem://');
  await db.use(ns: 'scenario', db: 'scenario');
  final crdt = await db.setCrdtAdapter(tablesToSync: _tables);
  return (db: db, crdt: crdt);
}

Future<Map<DBRecord, Map<String, dynamic>>> _snapshot(
    AdapterSurrealDB db) async {
  final rows = await db.select(_table);
  final out = <DBRecord, Map<String, dynamic>>{};
  if (rows == null) return out;
  for (final row in rows as List) {
    final map = Map<String, dynamic>.from(row as Map);
    final id = map.remove('id') as DBRecord;
    out[id] = map;
  }
  return out;
}

/// Fills [db] with [count] records, spaced apart so their HLCs are strictly
/// increasing (deterministic last-write-wins, like the fuzz oracle).
Future<void> _fill(AdapterSurrealDB db, int count,
    {String prefix = 'rec', String value = 'v'}) async {
  for (int i = 0; i < count; i++) {
    await db.upsert(DBRecord('test', '$prefix$i'), {
      'v': '$value$i',
      'pad': 'padding to make rows non-trivial $i',
    });
    // Give the CRDT event a beat so timestamps stay distinct.
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void _expectStatesEqual(
  Map<DBRecord, Map<String, dynamic>> expected,
  Map<DBRecord, Map<String, dynamic>> actual,
  String what,
) {
  final missing = expected.keys.where((k) => !actual.containsKey(k)).toList();
  final extra = actual.keys.where((k) => !expected.containsKey(k)).toList();
  final differing = <DBRecord>[];
  for (final e in expected.entries) {
    final a = actual[e.key];
    if (a != null && a['v'] != e.value['v']) differing.add(e.key);
  }
  expect(
    missing,
    isEmpty,
    reason: '$what: ${missing.length} record(s) missing '
        '(first: ${missing.take(3).toList()})',
  );
  expect(extra, isEmpty, reason: '$what: unexpected records $extra');
  expect(differing, isEmpty,
      reason: '$what: values differ on ${differing.take(3).toList()}');
}

void dotest() {
  test('empty device syncing with a full device receives every record (paged)',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      await _fill(a.db, 120);
      await b.crdt.sync(a.crdt.syncRepo, chunkSize: 10);
      _expectStatesEqual(await _snapshot(a.db), await _snapshot(b.db),
          'empty side must equal full side');
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  test('full device syncing with an empty device pushes every record (paged)',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      await _fill(a.db, 120);
      await a.crdt.sync(b.crdt.syncRepo, chunkSize: 10);
      _expectStatesEqual(await _snapshot(a.db), await _snapshot(b.db),
          'empty side must equal full side');
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  test('both devices syncing simultaneously converges completely (paged)',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      // Divergent data: shared ids written on b after a (b wins), plus
      // records unique to each side.
      await _fill(a.db, 60);
      await _fill(b.db, 30, prefix: 'rec', value: 'newer');
      await _fill(b.db, 30, prefix: 'bonly');
      // Expected end state on both sides: the pre-sync union with b's
      // newer values winning on the shared ids.
      final expected = await _snapshot(a.db);
      for (final e in (await _snapshot(b.db)).entries) {
        expected[e.key] = e.value;
      }
      expect(expected.length, 90);
      await Future.wait([
        a.crdt.sync(b.crdt.syncRepo, chunkSize: 7),
        b.crdt.sync(a.crdt.syncRepo, chunkSize: 7),
      ]);
      _expectStatesEqual(
          expected, await _snapshot(a.db), 'side a after concurrent sync');
      _expectStatesEqual(
          expected, await _snapshot(b.db), 'side b after concurrent sync');
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  test(
      'clearing data and crdt tables resurrects from the peer without wiping it',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      await _fill(a.db, 100);
      await b.crdt.sync(a.crdt.syncRepo, chunkSize: 10);
      _expectStatesEqual(
          await _snapshot(a.db), await _snapshot(b.db), 'pre-clear sync');

      // dion's fixed Clear Database: data tables first, then the crdt table
      // (deleting data re-stamps tombstones via the sync event; the crdt
      // delete must come after and wipe them), all in one transaction.
      await b.db.query('BEGIN TRANSACTION; DELETE FROM test; '
          'DELETE FROM crdt; COMMIT TRANSACTION;');
      expect(await _snapshot(b.db), isEmpty, reason: 'b must be empty');

      await b.crdt.sync(a.crdt.syncRepo, chunkSize: 10);
      _expectStatesEqual(await _snapshot(a.db), await _snapshot(b.db),
          'b must be resurrected from a');
      expect((await _snapshot(a.db)).length, 100,
          reason: 'a must not have lost anything');
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  test(
      'clearing only the data table propagates deletions to the peer (why Clear Database must also clear crdt)',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      await _fill(a.db, 20);
      await b.crdt.sync(a.crdt.syncRepo);
      expect((await _snapshot(b.db)).length, 20);

      // The OLD Clear Database behavior: delete data rows but keep crdt
      // rows. The sync event stamps fresh tombstones, which are newer than
      // everything the peer holds — so the peer is wiped too. This is
      // correct per-record last-write-wins; the fix belongs in the clear
      // operation, not in sync.
      await a.db.query('DELETE FROM test;');
      await b.crdt.sync(a.crdt.syncRepo);
      expect(await _snapshot(b.db), isEmpty,
          reason: 'fresh tombstones must win last-write-wins on the peer');
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  test('previously synced tombstones survive a peer clearing its crdt table',
      () async {
    final a = await _newDb();
    final b = await _newDb();
    try {
      // Delete a record on b, propagate the tombstone to a, then clear b
      // entirely. The tombstone still lives on a, so the record must NOT be
      // resurrected into b by the post-clear sync.
      await _fill(b.db, 10, prefix: 'shared');
      await a.crdt.sync(b.crdt.syncRepo);
      await b.db.delete(const DBRecord('test', 'shared3'));
      await b.crdt.sync(a.crdt.syncRepo);
      expect(await a.db.select(const DBRecord('test', 'shared3')), isNull);

      await b.db.query('BEGIN TRANSACTION; DELETE FROM test; '
          'DELETE FROM crdt; COMMIT TRANSACTION;');
      await b.crdt.sync(a.crdt.syncRepo, chunkSize: 3);
      final state = await _snapshot(b.db);
      expect(state.length, 9, reason: 'the deleted record stays deleted');
      expect(state.containsKey(const DBRecord('test', 'shared3')), isFalse);
    } finally {
      a.db.dispose();
      b.db.dispose();
    }
  });

  group('push HLC guard', () {
    test('a late push with an older HLC cannot overwrite newer data', () async {
      final a = await _newDb();
      try {
        const rec = DBRecord('test', 'rec');
        await a.db.upsert(rec, {'v': 1});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final oldMeta = await a.crdt.syncRepo.getSyncData(rec);
        final oldRow = await a.db.select(rec);
        expect(oldMeta, isNotNull);

        await a.db.upsert(rec, {'v': 2});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final newMeta = await a.crdt.syncRepo.getSyncData(rec);
        expect(newMeta!.hlc.compareTo(oldMeta!.hlc), greaterThan(0));

        // A straggler (concurrent sync that compared before v2 was written)
        // re-pushes v1. The guard must keep v2.
        await a.crdt.syncRepo.push(oldMeta, oldRow);
        final row = await a.db.select(rec);
        expect(row['v'], 2, reason: 'newer data must survive an older push');
        final meta = await a.crdt.syncRepo.getSyncData(rec);
        expect(meta!.hlc.toString(), newMeta.hlc.toString(),
            reason: 'the crdt row must not be restamped either');
      } finally {
        a.db.dispose();
      }
    });

    test('a late push with an older tombstone cannot delete newer data',
        () async {
      final a = await _newDb();
      try {
        const rec = DBRecord('test', 'rec');
        await a.db.upsert(rec, {'v': 1});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final oldMeta = await a.crdt.syncRepo.getSyncData(rec);
        expect(oldMeta, isNotNull);

        await a.db.upsert(rec, {'v': 2});
        await Future<void>.delayed(const Duration(milliseconds: 20));

        await a.crdt.syncRepo.push(oldMeta!, null);
        final row = await a.db.select(rec);
        expect(row, isNotNull,
            reason: 'an older tombstone must not delete a newer record');
        expect(row['v'], 2);
      } finally {
        a.db.dispose();
      }
    });

    test('pushing an equal HLC is a no-op, not a restamp', () async {
      final a = await _newDb();
      try {
        const rec = DBRecord('test', 'rec');
        await a.db.upsert(rec, {'v': 1});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final meta = await a.crdt.syncRepo.getSyncData(rec);
        final row = await a.db.select(rec);
        expect(meta, isNotNull);

        await a.crdt.syncRepo.push(meta!, row);
        await a.crdt.syncRepo.push(meta, null); // same HLC, conflicting flag
        final after = await a.db.select(rec);
        expect(after, isNotNull,
            reason: 'an equal-HLC push must not apply anything');
        expect(after['v'], 1);
        final metaAfter = await a.crdt.syncRepo.getSyncData(rec);
        expect(metaAfter!.hlc.toString(), meta.hlc.toString());
        expect(metaAfter.deleted, isFalse);
      } finally {
        a.db.dispose();
      }
    });

    test(
        'a push into an empty row applies (guard does not block fresh records)',
        () async {
      final a = await _newDb();
      try {
        const rec = DBRecord('test', 'fresh');
        final hlc = Hlc.now(a.crdt.nodeId);
        final meta = SyncData(hlc: hlc, deleted: false, entry: rec);
        await a.crdt.syncRepo.push(meta, {'v': 42});
        final row = await a.db.select(rec);
        expect(row, isNotNull);
        expect(row['v'], 42);
      } finally {
        a.db.dispose();
      }
    });
  });
}
