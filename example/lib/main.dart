import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:metis/metis.dart';
import 'package:path/path.dart' as p;

Future<void> copyPath(String from, String to) async {
  await Directory(to).create(recursive: true);
  await for (final file in Directory(from).list(recursive: true)) {
    final copyTo = p.join(to, p.relative(file.path, from: from));
    if (file is Directory) {
      await Directory(copyTo).create(recursive: true);
    } else if (file is File) {
      await File(file.path).copy(copyTo);
    } else if (file is Link) {
      await Link(copyTo).create(await file.target(), recursive: true);
    }
  }
}

void main() async {
  await RustLib.init();
  final testdir = Directory("runtimetest");
  if (!testdir.existsSync()) testdir.createSync(recursive: true);
  final file1 = Directory("${testdir.path}/test4.db");
  if (file1.existsSync()) file1.deleteSync(recursive: true);
  final file2 = Directory("${testdir.path}/test6.db");
  if (file2.existsSync()) file2.deleteSync(recursive: true);
  await test2();
}

Future<void> test2() async {
  var rec1;
  var rec2;
  var rec3;
  final db1 = await AdapterSurrealDB.newMem();
  await db1.use(db: "site", namespace: "data");
  await db1.setMigrationAdapter(
      version: 1,
      migrationName: "testdata",
      onMigrate: (db, from, to) async {
        print("Migrating from $from to $to");
      },
      onCreate: (db) async {
        await db.query(query: """
                      USE NS data;
                      USE DB site;

                      DEFINE TABLE users SCHEMAFULL;
                      DEFINE FIELD name ON TABLE users TYPE string;
                      DEFINE FIELD metadata ON TABLE users FLEXIBLE TYPE object;

                      DEFINE TABLE posts SCHEMAFULL;
                      DEFINE FIELD title ON TABLE posts TYPE string;
                      DEFINE FIELD body ON TABLE posts TYPE string;
                      DEFINE FIELD metadata ON TABLE posts FLEXIBLE TYPE object;
                      """);
      });
  print("Version is ${await db1.getAdapter<MigrationAdapter>().getVersion()}");
  await db1.setCrdtAdapter(
      tablesToSync: {const DBTable("users"), const DBTable("posts")});
  final res1 = await db1.insert(res: const DBTable("users"), data: {
    "name": "test",
    "metadata": {"test": "test"},
  });
  rec1 = res1["id"] as DBRecord;
  final res2 = await db1.insert(res: const DBTable("users"), data: {
    "name": "other",
    "metadata": {"test": "a"},
  });
  rec2 = res2["id"] as DBRecord;
  final res3 = await db1.insert(res: const DBTable("posts"), data: {
    "title": "This is a post",
    "body": "This is the body",
    "metadata": {"test": "Some Test"},
  });
  rec3 = res3["id"] as DBRecord;
  await db1.getAdapter<CrdtAdapter>().waitSync();
  final db2 = await AdapterSurrealDB.newMem();
  await db2.use(db: "site", namespace: "data");
  await db2.setMigrationAdapter(
      version: 1,
      migrationName: "testdata",
      onMigrate: (db, from, to) async {
        print("Migrating from $from to $to");
      },
      onCreate: (db) async {
        await db.query(query: """
                      USE NS data;
                      USE DB site;

                      DEFINE TABLE users SCHEMAFULL;
                      DEFINE FIELD name ON TABLE users TYPE string;
                      DEFINE FIELD metadata ON TABLE users FLEXIBLE TYPE object;

                      DEFINE TABLE posts SCHEMAFULL;
                      DEFINE FIELD title ON TABLE posts TYPE string;
                      DEFINE FIELD body ON TABLE posts TYPE string;
                      DEFINE FIELD metadata ON TABLE posts FLEXIBLE TYPE object;
                      """);
      });
  await db2.setCrdtAdapter(
      tablesToSync: {const DBTable("users"), const DBTable("posts")});
  await db2.getAdapter<CrdtAdapter>().mergeCrdt(db1.getAdapter());
  print("Users should be (${await db1.select(res: const DBTable("users"))})");
  print("Users is(${await db2.select(res: const DBTable("users"))})");
  await db2.updateMerge(res: rec1 as DBRecord, data: {
    "name": "this is updated",
    "metadata": {"test": "Some Test"},
  });
  await db2.insert(res: const DBTable("posts"), data: {
    "title": "This is a post",
    "body": "This is the body",
    "metadata": {"test": "Some Test"},
  });
  await db2.delete(res: rec2 as DBRecord);
  await db2.delete(res: rec3 as DBRecord);
  await db1.updateMerge(res: rec2, data: {
    "name": "Some other update",
    "metadata": {"test": "Yeet"},
  });
  await db1.getAdapter<CrdtAdapter>().waitSync();
  await db2.getAdapter<CrdtAdapter>().waitSync();
  await db2.getAdapter<CrdtAdapter>().merge(db1);
  print("Users is(${await db2.select(res: const DBTable("users"))})");
  print("Posts is(${await db2.select(res: const DBTable("posts"))})");
}

Future<void> printDB(SurrealDB db) async {
  final users = await db.select(res: const DBTable("users"));
  print("Users is(${users.length}): $users");
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'You have pushed the button this many times:',
            ),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
