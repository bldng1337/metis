import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crdt/crdt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/adapter/migration.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';

class MockSyncRepo extends SyncRepo {
  final SyncRepoData pointData;
  final Map<DBRecord, SyncData> data;
  final Map<DBRecord, dynamic> pullData;

  MockSyncRepo({
    required this.pointData,
    required this.data,
    required this.pullData,
  });

  @override
  Future<SyncRepoData> getSyncPointData() async => pointData;

  @override
  Stream<SyncData> querySyncData(int offset, int limit) async* {
    final list = data.values.toList();
    final end = (offset + limit > list.length) ? list.length : offset + limit;
    for (int i = offset; i < end; i++) {
      yield list[i];
    }
  }

  @override
  Future<SyncData?> getSyncData(DBRecord id) async => data[id];

  @override
  Future<dynamic> pull(SyncData meta) async => pullData[meta.entry];

  @override
  Future<void> push(SyncData meta, dynamic data) async {
    this.data[meta.entry] = meta;
    if (data != null) {
      pullData[meta.entry] = data;
    }
  }
}

SyncData _makeSyncData(String tb, String id, DateTime ts, int count,
    {bool deleted = false}) {
  return SyncData(
    hlc: Hlc(ts, count, 'node1'),
    deleted: deleted,
    entry: DBRecord(tb, id),
  );
}

SyncRepoData _makeRepoData(int entries, int version) {
  return SyncRepoData(
    version: version,
    entries: entries,
    tables: {
      SyncTable(
        table: const DBTable('test'),
        version: version,
        range: VersionRange.exact(version),
      ),
    },
  );
}

void main() {
  setUpAll(() async => await SurrealDB.ensureInitialized());
  dotest();
}

Future<
    ({
      AdapterSurrealDB serverDb,
      CrdtAdapter serverCrdt,
      AdapterSurrealDB clientDb,
      CrdtAdapter clientCrdt,
      SyncHttpClient httpClient,
      HttpServer server,
      Future<void> Function() dispose,
    })> _startRealDbHttpSync() async {
  const tables = {
    SyncTable(
      table: DBTable('test'),
      version: 1,
      range: VersionRange.exact(1),
    )
  };

  final serverDb = await AdapterSurrealDB.connect('mem://');
  await serverDb.use(db: 'test', ns: 'test');
  final serverCrdt = await serverDb.setCrdtAdapter(tablesToSync: tables);

  final clientDb = await AdapterSurrealDB.connect('mem://');
  await clientDb.use(db: 'test', ns: 'test');
  final clientCrdt = await clientDb.setCrdtAdapter(tablesToSync: tables);

  final httpServer = SyncHttpServer(port: 0, repo: serverCrdt.syncRepo);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    await httpServer.handle(req, req.requestedUri.path);
  });
  final httpClient = SyncHttpClient(
    url: 'http://${server.address.host}:${server.port}',
    client: HttpClient(),
  );

  return (
    serverDb: serverDb,
    serverCrdt: serverCrdt,
    clientDb: clientDb,
    clientCrdt: clientCrdt,
    httpClient: httpClient,
    server: server,
    dispose: () async {
      httpClient.dispose();
      await server.close(force: true);
      serverDb.dispose();
      clientDb.dispose();
    },
  );
}

void dotest() {
  late HttpServer server;
  late SyncHttpServer syncServer;
  late SyncHttpClient syncClient;
  late MockSyncRepo mockRepo;

  final testTime = DateTime.utc(2025, 1, 1);
  const testRecord = DBRecord('test', 'record1');

  setUp(() async {
    mockRepo = MockSyncRepo(
      pointData: _makeRepoData(1, 1),
      data: {
        testRecord: _makeSyncData('test', 'record1', testTime, 0),
      },
      pullData: {
        testRecord: {'field': 'value'},
      },
    );
    syncServer = SyncHttpServer(port: 0, repo: mockRepo);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    syncClient.dispose();
  });

  void serveRequests() {
    server.listen((req) async {
      await syncServer.handle(req, req.requestedUri.path);
    });
  }

  test('SyncHttpServer handles /getSyncPointData', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final result = await syncClient.getSyncPointData();
    expect(result.version, 1);
    expect(result.entries, 1);
    expect(result.tables.length, 1);
  });

  test('SyncHttpServer handles /getSyncData', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final result = await syncClient.getSyncData(testRecord);
    expect(result, isNotNull);
    expect(result!.entry, testRecord);
  });

  test('SyncHttpServer handles /pull', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final syncData = _makeSyncData('test', 'record1', testTime, 0);
    final result = await syncClient.pull(syncData);
    expect(result, isNotNull);
    expect(result, {'field': 'value'});
  });

  test('SyncHttpServer handles /push', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final syncData = _makeSyncData('test', 'newrecord', testTime, 0);
    await syncClient.push(syncData, {'new': 'data'});
    expect(
        mockRepo.data.containsKey(const DBRecord('test', 'newrecord')), isTrue);
  });

  test('SyncHttpServer handles /querySyncData', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final results = await syncClient.querySyncData(0, 10).toList();
    expect(results.length, 1);
    expect(results.first.entry, testRecord);
  });

  test('SyncHttpServer returns 404 for unknown path', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    try {
      final request = await syncClient.client.postUrl(Uri.parse(
        'http://${server.address.host}:${server.port}/unknown',
      ));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({}));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
    } catch (e) {
      fail('Should not throw: $e');
    }
  });

  test('SyncHttpServer returns 400 for non-JSON content type', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final request = await syncClient.client.postUrl(Uri.parse(
      'http://${server.address.host}:${server.port}/getSyncPointData',
    ));
    request.headers.contentType = ContentType.text;
    request.write('{}');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('SyncHttpClient and SyncHttpServer roundtrip all endpoints', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());

    final pointData = await syncClient.getSyncPointData();
    expect(pointData.version, mockRepo.pointData.version);
    expect(pointData.entries, mockRepo.pointData.entries);

    final syncData = await syncClient.getSyncData(testRecord);
    expect(syncData, isNotNull);
    expect(syncData!.entry.tb, 'test');
    expect(syncData.entry.id, 'record1');

    final pulled = await syncClient.pull(syncData);
    expect(pulled, {'field': 'value'});

    final newRecord = _makeSyncData('test', 'pushed1', testTime, 1);
    await syncClient.push(newRecord, {'pushed': true});
    expect(mockRepo.data[const DBRecord('test', 'pushed1')], isNotNull);

    final queried = await syncClient.querySyncData(0, 100).toList();
    expect(queried.isNotEmpty, isTrue);
  });

  test('SyncHttpServer handles empty querySyncData', () async {
    final emptyRepo = MockSyncRepo(
      pointData: _makeRepoData(0, 1),
      data: {},
      pullData: {},
    );
    final emptyServer = SyncHttpServer(port: 0, repo: emptyRepo);
    final testServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    testServer.listen((req) async {
      await emptyServer.handle(req, req.requestedUri.path);
    });
    syncClient = SyncHttpClient(
        url: 'http://${testServer.address.host}:${testServer.port}',
        client: HttpClient());

    final results = await syncClient.querySyncData(0, 10).toList();
    expect(results, isEmpty);
    await testServer.close(force: true);
  });

  test('SyncHttpServer getSyncData returns null for missing record', () async {
    serveRequests();
    syncClient = SyncHttpClient(
        url: 'http://${server.address.host}:${server.port}',
        client: HttpClient());
    final result =
        await syncClient.getSyncData(const DBRecord('test', 'missing'));
    expect(result, isNull);
  });

  test('SyncHttpServer handles /querySyncData with pagination', () async {
    final manyData = <DBRecord, SyncData>{};
    final manyPull = <DBRecord, dynamic>{};
    for (int i = 0; i < 5; i++) {
      final record = DBRecord('test', 'item$i');
      manyData[record] = _makeSyncData('test', 'item$i', testTime, i);
      manyPull[record] = {'val': i};
    }
    final paginatedRepo = MockSyncRepo(
      pointData: _makeRepoData(5, 1),
      data: manyData,
      pullData: manyPull,
    );
    final paginatedServer = SyncHttpServer(port: 0, repo: paginatedRepo);
    final testServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    testServer.listen((req) async {
      await paginatedServer.handle(req, req.requestedUri.path);
    });
    syncClient = SyncHttpClient(
        url: 'http://${testServer.address.host}:${testServer.port}',
        client: HttpClient());

    final page1 = await syncClient.querySyncData(0, 2).toList();
    final page2 = await syncClient.querySyncData(2, 2).toList();
    final page3 = await syncClient.querySyncData(4, 2).toList();
    expect(page1.length, 2);
    expect(page2.length, 2);
    expect(page3.length, 1);
    await testServer.close(force: true);
  });

  test('end-to-end sync over HTTP with real mem:// database', () async {
    final stack = await _startRealDbHttpSync();
    try {
      // Server -> Client: insert on the server DB, sync over HTTP, then verify
      // the record (and its CRDT metadata) arrived on the client DB.
      const r1 = DBRecord('test', 'server1');
      await stack.serverDb.upsert(r1, {'value': 'from-server'});
      await Future.delayed(const Duration(milliseconds: 100));

      final pointData = await stack.httpClient.getSyncPointData();
      expect(pointData.entries, 1);
      expect(pointData.version, 1);

      await stack.clientCrdt.sync(stack.httpClient);

      final clientR1 = await stack.clientDb.select(r1);
      expect(clientR1, isNotNull);
      expect(clientR1['value'], 'from-server');

      // Client -> Server: insert on the client DB, sync over HTTP, then verify
      // the record made it back to the server DB.
      const r2 = DBRecord('test', 'client1');
      await stack.clientDb.upsert(r2, {'value': 'from-client'});
      await Future.delayed(const Duration(milliseconds: 100));

      await stack.clientCrdt.sync(stack.httpClient);

      final serverR2 = await stack.serverDb.select(r2);
      expect(serverR2, isNotNull);
      expect(serverR2['value'], 'from-client');

      // Delete propagation: delete on the server, sync, then verify the record
      // is removed from the client as well.
      await stack.serverDb.delete(r1);
      await Future.delayed(const Duration(milliseconds: 100));

      await stack.clientCrdt.sync(stack.httpClient);

      final clientR1AfterDelete = await stack.clientDb.select(r1);
      expect(clientR1AfterDelete, isNull);
    } finally {
      await stack.dispose();
    }
  });
}
