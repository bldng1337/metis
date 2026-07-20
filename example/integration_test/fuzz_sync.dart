import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

import 'fuzz_dataclass.dart';

/// A pluggable synchronization mechanism between a local [CrdtAdapter] and a
/// remote [SyncRepo].
///
/// This is the swap point for the fuzz tests: future sync transports
/// (websocket, gRPC, ...) are added as new subclasses, and the whole scenario
/// reruns against them unchanged.
abstract class FuzzSyncStrategy {
  String get name;

  /// Synchronize [local] with [remote]. Must converge both sides to the
  /// union of the two states.
  Future<void> sync(CrdtAdapter local, SyncRepo remote);
}

/// Synchronizes in-process, calling [CrdtAdapter.sync] directly against the
/// remote adapter's repo. Exercises the CRDT event wiring, [CrdtAdapterRepo],
/// and the embedded SurrealDB codec.
class DirectFuzzSync extends FuzzSyncStrategy {
  @override
  String get name => 'direct';

  @override
  Future<void> sync(CrdtAdapter local, SyncRepo remote) =>
      local.sync(remote);
}

/// Synchronizes over real HTTP using [SyncHttpServer] / [SyncHttpClient],
/// exercising the full JSON serialization + HTTP plumbing. A fresh server is
/// stood up for every [sync] call to keep strategies stateless.
class HttpFuzzSync extends FuzzSyncStrategy {
  @override
  String get name => 'http';

  @override
  Future<void> sync(CrdtAdapter local, SyncRepo remote) async {
    final handler = SyncHttpServer(port: 0, repo: remote);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((req) async {
      await handler.handle(req, req.requestedUri.path);
    });
    final httpClient = SyncHttpClient(
      url: 'http://${server.address.host}:${server.port}',
      client: HttpClient(),
    );
    try {
      await local.sync(httpClient);
    } finally {
      httpClient.dispose();
      await sub.cancel();
      await server.close(force: true);
    }
  }
}

/// One recorded mutation, for reproducible failure diagnostics.
class _OpLogEntry {
  final int step;
  final String op; // 'upsert' | 'delete'
  final int edge; // index of the edge DB the op targeted
  final String recordId;
  _OpLogEntry(this.step, this.op, this.edge, this.recordId);

  @override
  String toString() => '#$step $op on edge$edge -> fuzz:$recordId';
}

/// Snapshot of a DB's live `fuzz` table: record id -> record.
typedef FuzzState = Map<DBRecord, FuzzRecord>;

const _table = DBTable('fuzz');

/// Connect an in-memory DB and set up its CRDT adapter for the [fuzz] table.
Future<({AdapterSurrealDB db, CrdtAdapter crdt})> _newDb() async {
  final db = await AdapterSurrealDB.connect('mem://');
  await db.use(ns: 'fuzz', db: 'fuzz');
  final crdt = await db.setCrdtAdapter(
    tablesToSync: const {
      SyncTable(
        table: _table,
        version: 1,
        range: VersionRange.exact(1),
      ),
    },
  );
  return (db: db, crdt: crdt);
}

/// Read all live records from `db`, indexed by their record id.
Future<FuzzState> _snapshot(AdapterSurrealDB db) async {
  final rows = await db.select(_table);
  final out = <DBRecord, FuzzRecord>{};
  if (rows == null) return out;
  for (final row in rows as List) {
    final map = Map<String, dynamic>.from(row as Map);
    final id = map.remove('id') as DBRecord;
    final rec = FuzzRecord.fromMap(map);
    if (rec != null) out[id] = rec;
  }
  return out;
}

/// The fuzz scenario.
///
/// Creates one "main" DB (B) plus [edgeCount] edge DBs. Applies [mutations]
/// random upsert/delete operations, each mirrored onto main and a single edge,
/// so that main ends up holding the unique fully-merged state. Then syncs the
/// edges together and asserts each edge equals main.
///
/// Oracle correctness: every operation writes the *same content* to both main
/// and the chosen edge. Because of [opDelayMs], later steps always get strictly
/// later HLC timestamps than earlier steps, so last-write-wins picks a unique
/// winner everywhere. Main sees every step in order, so its value for any record
/// is simply the content of the last step that touched it — which is exactly
/// what every edge converges to after cross-sync (the globally-latest step).
/// Main never participates in the sync phase, so its slightly-earlier mirrored
/// HLC can never leak back out and overwrite a newer value on the edges.
///
/// [seed] drives all randomness; reuse it to reproduce a failure.
Future<void> runFuzz(
  FuzzSyncStrategy strategy, {
  required int seed,
  int edgeCount = 2,
  int mutations = 40,
  int recordPool = 8,
  int opDelayMs = 5,
}) async {
  assert(edgeCount >= 2, 'Need at least two edges to cross-sync.');
  final rng = FuzzRng(seed);
  final opLog = <_OpLogEntry>[];

  final dbs = <AdapterSurrealDB>[];
  final crdts = <CrdtAdapter>[];
  try {
    // dbs[0] is main (the oracle); dbs[1..] are the edges that cross-sync.
    final main = await _newDb();
    dbs.add(main.db);
    crdts.add(main.crdt);
    for (int i = 0; i < edgeCount; i++) {
      final e = await _newDb();
      dbs.add(e.db);
      crdts.add(e.crdt);
    }

    // Fixed pool of record ids so deletes and re-upserts collide.
    final ids = [
      for (int i = 0; i < recordPool; i++) DBRecord('fuzz', 'rec$i'),
    ];

    // Track which records are live on each edge. A delete is only issued when
    // the record actually exists on the targeted edge: a real user can't delete
    // a record they never created, and crucially the CRDT's table event does
    // NOT fire when you delete a non-existent record (SurrealDB treats it as a
    // no-op), so the tombstone timestamp would never advance. Issuing blind
    // deletes would therefore diverge from the LWW oracle for a reason that is
    // not a sync bug. Upserts after a delete still resurrect the record.
    final liveOnEdge = List<Set<String>>.generate(
        edgeCount, (_) => <String>{});

    for (int step = 0; step < mutations; step++) {
      final edgeIndex = 1 + rng.nextInt(edgeCount); // edges are dbs[1..]
      final edgeLive = liveOnEdge[edgeIndex - 1];
      final id = rng.nextElement(ids);
      // A delete is only valid if the record is currently live on this edge.
      final isDelete = rng.nextBool() && edgeLive.contains(id.id as String);

      if (isDelete) {
        await dbs[0].delete(id);
        await dbs[edgeIndex].delete(id);
        edgeLive.remove(id.id as String);
        opLog.add(_OpLogEntry(step, 'delete', edgeIndex, id.id as String));
      } else {
        final rec = FuzzRecord.random(rng, relation: rng.nextElement(ids));
        // Mirror the exact same write onto both DBs so main sees every op.
        await dbs[0].upsert(id, rec.toMap());
        await dbs[edgeIndex].upsert(id, rec.toMap());
        edgeLive.add(id.id as String);
        opLog.add(_OpLogEntry(step, 'upsert', edgeIndex, id.id as String));
      }

      // Determinism lever: space ops apart so each write to a given record gets
      // a distinct, globally-ordered HLC timestamp. The CRDT derives its node
      // id from the record id (not the DB), so two writes to the same record in
      // the same millisecond on different DBs produce an exact HLC tie
      // (compareTo==0) and sync skips them, breaking convergence. opDelayMs must
      // exceed the timer granularity so consecutive ops land in distinct ms.
      await Future.delayed(Duration(milliseconds: opDelayMs));
    }

    // Sync phase: cross-sync every edge with its ring neighbor, both directions.
    // Two edges -> A<->C both ways. More edges -> a ring that still converges
    // because last-write-wins is total under distinct timestamps.
    final rounds = edgeCount;
    for (int round = 0; round < rounds; round++) {
      for (int i = 0; i < edgeCount; i++) {
        final a = crdts[1 + i];
        final b = crdts[1 + (i + 1) % edgeCount];
        await strategy.sync(a, b.syncRepo);
        await strategy.sync(b, a.syncRepo);
      }
    }

    // Verify: every edge must equal main (the oracle).
    final mainState = await _snapshot(dbs[0]);

    String describeMismatch(FuzzState actual, DBRecord id) {
      final m = mainState[id];
      final e = actual[id];
      if (m == null && e != null) {
        return '  fuzz:${id.id} present on edge but deleted on main\n'
            '    edge: $e';
      }
      if (m != null && e == null) {
        return '  fuzz:${id.id} missing on edge but present on main\n'
            '    main: $m';
      }
      return '  fuzz:${id.id} differs\n    main: $m\n    edge: $e';
    }

    final mismatchDetail = StringBuffer();
    for (int i = 0; i < edgeCount; i++) {
      final edgeState = await _snapshot(dbs[1 + i]);
      final allIds = <DBRecord>{...mainState.keys, ...edgeState.keys};
      final badIds = <DBRecord>[];
      for (final id in allIds) {
        if (mainState[id] != edgeState[id]) {
          badIds.add(id);
          mismatchDetail
            ..writeln('edge $i (${strategy.name}, seed $seed):')
            ..writeln(describeMismatch(edgeState, id));
        }
      }
      if (badIds.isNotEmpty) {
        fail('Fuzz mismatch on edge $i (${strategy.name}, seed $seed): '
            '${badIds.length} record(s) diverged from main.\n'
            'Reproduce with seed=$seed.\n'
            'Op log:\n${opLog.map((e) => '  $e').join('\n')}\n'
            'Details:\n$mismatchDetail');
      }
    }
  } finally {
    for (final db in dbs) {
      db.dispose();
    }
  }
}

void dotest() {
  const seeds = [1, 2, 3];
  final strategies = <FuzzSyncStrategy>[
    DirectFuzzSync(),
    HttpFuzzSync(),
  ];

  for (final strategy in strategies) {
    group('Fuzz/${strategy.name}', () {
      for (final seed in seeds) {
        test('converges across edges (seed $seed)', () async {
          await runFuzz(
            strategy,
            seed: seed,
            edgeCount: 2,
            mutations: 40,
            recordPool: 8,
          );
        });
      }
    });
  }

  group('Fuzz/http-full', () {
    // A heavier run under the HTTP strategy to stress the codec path.
    test('converges with 3 edges and 60 mutations (seed 7)', () async {
      await runFuzz(
        HttpFuzzSync(),
        seed: 7,
        edgeCount: 3,
        mutations: 60,
        recordPool: 10,
      );
    });
  });
}
