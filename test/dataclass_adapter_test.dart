import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/dataclass.dart';

/// Unit tests for [DBDataClassAdapter]'s multi-row reads.
///
/// flutter_surrealdb exposes query/select as `Future<dynamic>`, so these
/// fakes deliberately return dynamically typed results. With the old
/// implementation a bare `.cast()` could not recover its type argument
/// across that boundary and every read failed with
/// `type 'CastIterable<dynamic, dynamic>' is not a subtype of type
/// 'Iterable<Map<String, dynamic>>'`.
void main() {
  const w1 = DBRecord('widget', 'w1');
  const w2 = DBRecord('widget', 'w2');

  List<Map<String, dynamic>> sampleRows() => [
        {'id': w1, 'name': 'one', 'index': 1},
        {'id': w2, 'name': 'two'},
      ];

  DBDataClassAdapter makeAdapter(_FakeSurrealDb db) {
    final adapter = DBDataClassAdapter(db: db);
    adapter.registerDataClass(const DBTable('widget'), _Widget.fromJson);
    return adapter;
  }

  group('DBDataClassAdapter multi-row decoding', () {
    test('queryDataClasses decodes dynamically-typed result sets', () async {
      final db = _FakeSurrealDb()..queryResult = [sampleRows()];
      final adapter = makeAdapter(db);

      final decoded = await adapter.queryDataClasses<_Widget>(
        query: 'SELECT * FROM widget',
      ).toList();

      expect(decoded.map((w) => w.id.id), ['w1', 'w2']);
      expect(decoded.first.name, 'one');
      expect(decoded.last.name, 'two');
      // Defaults apply for fields absent from the row.
      expect(decoded.last.index, 0);
    });

    test('queryDataClasses skips null rows', () async {
      final db = _FakeSurrealDb()
        ..queryResult = [
          [sampleRows().first, null, sampleRows().last],
        ];
      final adapter = makeAdapter(db);

      final decoded = await adapter.queryDataClasses<_Widget>(
        query: 'SELECT * FROM widget',
      ).toList();

      expect(decoded.map((w) => w.id.id), ['w1', 'w2']);
    });

    test('selectDataClasses decodes dynamically-typed row lists', () async {
      final db = _FakeSurrealDb()..selectResult = sampleRows();
      final adapter = makeAdapter(db);

      final decoded =
          await adapter.selectDataClasses<_Widget>(const DBTable('widget'))
              .toList();

      expect(decoded.map((w) => w.id.id), containsAll(['w1', 'w2']));
    });

    test(
      'rows without a hydrated DBRecord id fail with a clear error',
      () async {
        // The loader contract is that surreal record fields arrive hydrated
        // as DBRecord instances; encoding them back into plain maps breaks
        // that contract and must surface as an ArgumentError, not a
        // TypeError.
        final deserialized = [
          for (final row in sampleRows())
            <String, dynamic>{
              ...row,
              'id': {
                'tb': row['id'].tb,
                'id': row['id'].id,
              },
            },
        ];
        final db = _FakeSurrealDb()..selectResult = deserialized;
        final adapter = makeAdapter(db);

        await expectLater(
          adapter.selectDataClasses<_Widget>(const DBTable('widget')).toList(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('Row without a DBRecord id'),
            ),
          ),
        );
      },
    );
  });
}

class _Widget with DBConstClass {
  final DBRecord id;
  final String name;
  final int index;

  const _Widget(this.id, this.name, this.index);

  factory _Widget.fromJson(Map<String, dynamic> json) => _Widget(
        json['id'] as DBRecord,
        json['name'] as String,
        json['index'] as int? ?? 0,
      );

  @override
  DBRecord get dbId => id;

  @override
  Map<String, dynamic> toDBJson() => {'name': name, 'index': index};

  @override
  bool operator ==(Object other) =>
      other is _Widget && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Scriptable stand-in for fsdb's client. The class is `implements`d so no
/// constructor (and therefore no native library bootstrap) runs; unhandled
/// members fail loudly instead of silently succeeding.
class _FakeSurrealDb implements SurrealDB {
  Object? selectResult;
  Object? queryResult;

  @override
  Future<dynamic> select(Resource thing) async => selectResult;

  @override
  Future<dynamic> query(String query, {Map<String, dynamic>? vars}) async =>
      queryResult;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
