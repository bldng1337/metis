# metis

`metis` is a Flutter/Dart package that adds adapter-based utilities on top of
`flutter_surrealdb` for common local-first patterns: schema/data migrations,
typed data class loading/saving, and CRDT-style sync metadata with transport helpers.

## Features

- `AdapterSurrealDB`: wraps a `SurrealDB` instance and manages adapter lifecycle.
- `MigrationAdapter`: runs `onCreate`/`onMigrate` callbacks based on stored version.
- `DBDataClassAdapter`: register typed model loaders and save/query/delete by `DBRecord`.
- `CrdtAdapter`: tracks changes in a sync table and synchronizes data with conflict resolution.
- `SyncRepo`, `SyncHttpClient`, and `SyncHttpServer`: repository + HTTP transport for sync.
- `KeyValueStore`: lightweight key-value helper backed by SurrealDB records.

## Getting started

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  metis:
    git:
      url: https://github.com/bldng1337/metis.git
```

Then install dependencies:

```bash
flutter pub get
```

Import the package:

```dart
import 'package:metis/metis.dart';
```

## Usage

### 1) Connect and register adapters

```dart
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/metis.dart';

Future<void> setup() async {
  final db = await AdapterSurrealDB.connect('ws://127.0.0.1:8000/rpc');
  await db.use(ns: 'app', db: 'main');

  await db.setMigrationAdapter(
    migrationName: 'app_schema',
    version: 1,
    onCreate: (surreal) async {
      await surreal.query('DEFINE TABLE notes SCHEMALESS;');
    },
    onMigrate: (surreal, from, to) async {
      // apply migration steps
    },
  );

  await db.setDataClassAdapter();
}
```

### 2) Define and persist typed data classes

```dart
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/metis.dart';

class Note with DBConstClass {
  final String id;
  final String text;

  Note({required this.id, required this.text});

  @override
  DBRecord get dbId => DBRecord('notes', id);

  @override
  Map<String, dynamic> toDBJson() => {'text': text};

  static Note fromJson(Map<String, dynamic> data) {
    final record = data['id'] as DBRecord;
    return Note(id: record.id.toString(), text: data['text'] as String);
  }
}

Future<void> saveAndLoad(AdapterSurrealDB db) async {
  final dataAdapter = db.getAdapter<DBDataClassAdapter>();
  dataAdapter.registerDataClass<Note>(Note.fromJson);

  final note = Note(id: 'n1', text: 'Hello Metis');
  await dataAdapter.save(note);

  final loaded = await dataAdapter.selectDataClass<Note>(note.dbId);
  print(loaded?.text);
}
```

### 3) Enable CRDT sync + HTTP transport

```dart
import 'dart:io';

import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/metis.dart';

Future<void> enableSync(AdapterSurrealDB db) async {
  final crdt = await db.setCrdtAdapter(
    tablesToSync: {
      const SyncTable(
        table: DBTable('notes'),
        version: 1,
        range: VersionRange.exact(1),
      ),
    },
  );

  // Server side
  final server = SyncHttpServer(repo: crdt.syncRepo);
  unawaited(server.start());

  // Client side
  final remote = SyncHttpClient(
    url: 'http://127.0.0.1:9876',
    client: HttpClient(),
  );

  await crdt.sync(remote, onProgress: (progress, total) {
    print('sync $progress / $total');
  });
}
```

## Exports

`package:metis/metis.dart` exports:

- `flutter_surrealdb`
- `adapter.dart`
- `adapter/crdt.dart`
- `adapter/migration.dart`
- `client.dart`
