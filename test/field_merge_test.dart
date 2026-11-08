import 'dart:convert';
import 'dart:math';

import 'package:crdt/crdt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/json_diff.dart';
import 'package:metis/adapter/sync/fields.dart';

Map<String, dynamic> _recompute(Map<String, dynamic> row) {
  final data = (row['episodedata'] as Map?) ?? const {};
  return {
    ...row,
    'read': data.values.where((e) => e['finished'] == true).length,
  };
}

const _schema = FieldCrdt(
  groups: {
    'source': ['entry', 'original'],
  },
  passive: {'source'},
  lww: {'rating': null, 'note': null, 'episode': 0},
  maps: {
    'episodedata': FieldMap(
      fields: {'bookmark': false, 'finished': false, 'progress': null},
      sets: {'quotes'},
    ),
  },
  sets: {'categories'},
  derived: {'read'},
  recompute: _recompute,
);

final _epoch = DateTime.utc(2026, 1, 1);
Hlc at(int minute, [String node = 'A']) =>
    Hlc(_epoch.add(Duration(minutes: minute)), 0, node);

FieldDoc doc(
  Map<String, dynamic>? row, {
  String node = 'A',
  int base = 0,
  Map<String, int> stamps = const {},
  Map<String, List<SetMark>> marks = const {},
  bool deleted = false,
  int? hlc,
  Map<String, Hlc>? heads,
}) {
  final newest = hlc ?? stamps.values.fold<int>(base, max);
  return FieldDoc(
    row: row,
    deleted: deleted,
    hlc: at(newest, node),
    base: at(base, node),
    stamps: {for (final e in stamps.entries) e.key: at(e.value, node)},
    marks: marks,
    heads: heads ?? {node: at(newest, node)},
  );
}

Map<String, dynamic> ep(
        {bool bookmark = false,
        bool finished = false,
        String? progress,
        List<Object?> quotes = const []}) =>
    {
      'bookmark': bookmark,
      'finished': finished,
      'progress': progress,
      'quotes': quotes,
    };

Map<String, dynamic> merged(FieldDoc a, FieldDoc b) =>
    mergeFieldDocs(_schema, a, b).row!;

void main() {
  group('field merging', () {
    test('independent edits to one episode both survive', () {
      final a = doc({
        'episodedata': {'e3': ep(bookmark: true)}
      }, stamps: {
        'episodedata/e3/bookmark': 5
      });
      final b = doc({
        'episodedata': {'e3': ep(finished: true)}
      }, node: 'B', stamps: {
        'episodedata/e3/finished': 6
      });
      expect(merged(a, b)['episodedata']['e3'],
          ep(bookmark: true, finished: true));
    });

    test('progress on different episodes is a union', () {
      final a = doc({
        'episodedata': {'e1': ep(finished: true)}
      }, stamps: {
        'episodedata/e1/finished': 5
      });
      final b = doc({
        'episodedata': {'e2': ep(finished: true)}
      }, node: 'B', stamps: {
        'episodedata/e2/finished': 6
      });
      expect(merged(a, b)['episodedata'].keys, unorderedEquals(['e1', 'e2']));
    });

    test('the newer write to one field wins', () {
      final a = doc({'note': 'old'}, stamps: {'note': 5});
      final b = doc({'note': 'new'}, node: 'B', stamps: {'note': 6});
      expect(merged(a, b)['note'], 'new');
      expect(merged(b, a)['note'], 'new');
    });

    test('a refresh does not touch user fields', () {
      final a = doc({
        'entry': 'old',
        'original': 'old',
        'note': 'mine',
      }, stamps: {
        'note': 5
      });
      final b = doc({
        'entry': 'fresh',
        'original': 'fresh',
        'note': null,
      }, node: 'B', stamps: {
        '@source': 9
      });
      final row = merged(a, b);
      expect(row['entry'], 'fresh');
      expect(row['note'], 'mine');
    });

    test('a group is taken whole from one side', () {
      final a = doc({'entry': 'a', 'original': 'a'}, stamps: {'@source': 5});
      final b = doc({'entry': 'b'}, node: 'B', stamps: {'@source': 6});
      final row = merged(a, b);
      expect(row['entry'], 'b');
      expect(row.containsKey('original'), isFalse);
    });

    test('undeclared fields behave as one last-write-wins group', () {
      final a = doc({'x': 1, 'y': 1}, stamps: {'@rest': 5});
      final b = doc({'x': 2, 'y': 2}, node: 'B', stamps: {'@rest': 6});
      final row = merged(a, b);
      expect(row['x'], 2);
      expect(row['y'], 2);
    });

    test('an unstamped default loses to any real value', () {
      final a = doc({
        'episodedata': {'e1': ep(bookmark: true)}
      }, base: 1);
      final b = doc({
        'episodedata': <String, dynamic>{},
        'rating': null,
      }, node: 'B', base: 50);
      expect(merged(a, b)['episodedata']['e1']['bookmark'], isTrue);
    });

    test('clearing a value beats an older set', () {
      final a = doc({
        'episodedata': {'e1': ep(bookmark: true)}
      }, stamps: {
        'episodedata/e1/bookmark': 5
      });
      final b = doc({
        'episodedata': <String, dynamic>{}
      }, node: 'B', stamps: {
        'episodedata/e1/bookmark': 8
      });
      expect(merged(a, b)['episodedata'], isEmpty);
    });

    test('a cleared value keeps its stamp through later merges', () {
      final cleared = doc({
        'episodedata': <String, dynamic>{}
      }, node: 'B', stamps: {
        'episodedata/e1/bookmark': 8
      });
      final older = doc({
        'episodedata': {'e1': ep(bookmark: true)}
      }, stamps: {
        'episodedata/e1/bookmark': 5
      });
      final first = mergeFieldDocs(_schema, older, cleared);
      expect(first.stamps['episodedata/e1/bookmark'], at(8, 'B'));
      expect(mergeFieldDocs(_schema, first, older).row!['episodedata'], isEmpty);
    });

    test('entries with only default values are dropped', () {
      final a = doc({
        'episodedata': {'e1': ep()}
      });
      final b = doc({'episodedata': <String, dynamic>{}}, node: 'B');
      expect(merged(a, b)['episodedata'], isEmpty);
    });

    test('extra entry fields are kept', () {
      final a = doc({
        'episodedata': {
          'e1': {...ep(finished: true), 'episode': 'uid'},
        }
      }, stamps: {
        'episodedata/e1/finished': 5
      });
      final b = doc({'episodedata': <String, dynamic>{}}, node: 'B', base: 1);
      expect(merged(a, b)['episodedata']['e1']['episode'], 'uid');
    });

    test('map keys may contain slashes', () {
      const key = 'https://x.y/ep/1';
      final a = doc({
        'episodedata': <String, dynamic>{}
      }, stamps: {
        'episodedata/$key/bookmark': 9
      });
      final b = doc({
        'episodedata': {key: ep(bookmark: true)}
      }, node: 'B', stamps: {
        'episodedata/$key/bookmark': 5
      });
      expect(merged(a, b)['episodedata'], isEmpty);
    });
  });

  group('set merging', () {
    test('additions on both sides are kept', () {
      final a = doc({'categories': ['x']},
          marks: {'categories': [SetMark('x', at(5), true)]});
      final b = doc({'categories': ['y']},
          node: 'B',
          marks: {'categories': [SetMark('y', at(6, 'B'), true)]});
      expect(merged(a, b)['categories'], ['x', 'y']);
    });

    test('a newer removal beats an older presence', () {
      final a = doc({'categories': ['x']}, base: 1);
      final b = doc({'categories': <Object>[]},
          node: 'B',
          marks: {'categories': [SetMark('x', at(6, 'B'), false)]});
      expect(merged(a, b)['categories'], isEmpty);
    });

    test('a newer re-add beats an older removal', () {
      final a = doc({'categories': ['x']},
          marks: {'categories': [SetMark('x', at(9), true)]});
      final b = doc({'categories': <Object>[]},
          node: 'B',
          marks: {'categories': [SetMark('x', at(6, 'B'), false)]});
      expect(merged(a, b)['categories'], ['x']);
    });

    test('per-entry sets merge per element', () {
      final a = doc({
        'episodedata': {
          'e1': ep(quotes: [
            {'t': 'a'}
          ])
        }
      }, marks: {
        'episodedata/e1/quotes': [
          SetMark({'t': 'a'}, at(5), true)
        ]
      });
      final b = doc({
        'episodedata': {
          'e1': ep(quotes: [
            {'t': 'b'}
          ])
        }
      }, node: 'B', marks: {
        'episodedata/e1/quotes': [
          SetMark({'t': 'b'}, at(6, 'B'), true)
        ]
      });
      expect(merged(a, b)['episodedata']['e1']['quotes'], [
        {'t': 'a'},
        {'t': 'b'}
      ]);
    });
  });

  group('deletes', () {
    final live = {'entry': 'e', 'note': 'n'};

    test('a delete beats older activity', () {
      final a = doc(live, stamps: {'note': 5});
      final tomb = doc(null, node: 'B', deleted: true, hlc: 8);
      final result = mergeFieldDocs(_schema, a, tomb);
      expect(result.deleted, isTrue);
      expect(result.row, isNull);
    });

    test('newer user activity keeps the row whole', () {
      final a = doc(live, stamps: {'note': 9});
      final tomb = doc(null, node: 'B', deleted: true, hlc: 8);
      final result = mergeFieldDocs(_schema, a, tomb);
      expect(result.deleted, isFalse);
      expect(result.row, live);
    });

    test('newer passive activity does not resurrect a deleted row', () {
      final a = doc(live, base: 1, stamps: {'@source': 20});
      final tomb = doc(null, node: 'B', deleted: true, hlc: 8);
      expect(mergeFieldDocs(_schema, a, tomb).deleted, isTrue);
    });

    test('heads join even when one side is dropped', () {
      final a = doc(live, stamps: {'note': 5});
      final tomb = doc(null, node: 'B', deleted: true, hlc: 8);
      final result = mergeFieldDocs(_schema, a, tomb);
      expect(result.heads.keys, unorderedEquals(['A', 'B']));
    });
  });

  group('derived fields', () {
    test('are recomputed from the merged row', () {
      final a = doc({
        'read': 1,
        'episodedata': {'e1': ep(finished: true)}
      }, stamps: {
        'episodedata/e1/finished': 5
      });
      final b = doc({
        'read': 1,
        'episodedata': {'e2': ep(finished: true)}
      }, node: 'B', stamps: {
        'episodedata/e2/finished': 6
      });
      expect(merged(a, b)['read'], 2);
    });
  });

  group('compareHeads', () {
    test('orders by what each side has seen', () {
      expect(compareHeads({'A': at(1)}, {'A': at(1)}), SyncOrder.same);
      expect(compareHeads({'A': at(2)}, {'A': at(1)}), SyncOrder.newer);
      expect(compareHeads({'A': at(1)}, {'A': at(2)}), SyncOrder.older);
      expect(compareHeads({'A': at(1), 'B': at(1, 'B')}, {'A': at(1)}),
          SyncOrder.newer);
      expect(compareHeads({'A': at(2)}, {'B': at(1, 'B')}),
          SyncOrder.concurrent);
    });
  });

  group('FieldDoc wire format', () {
    test('round trips through JSON', () {
      final original = doc({
        'note': 'n'
      }, stamps: {
        'note': 3
      }, marks: {
        'categories': [SetMark('x', at(4), false)]
      });
      final back = FieldDoc.fromWire(
          jsonDecode(jsonEncode(original.toWire())) as Map<String, dynamic>);
      expect(canonicalJson(back.toWire()), canonicalJson(original.toWire()));
      expect(FieldDoc.isWire(original.toWire()), isTrue);
      expect(FieldDoc.isWire({'row': 1}), isFalse);
    });
  });

  group('schema', () {
    test('rejects a field declared twice', () {
      expect(
          () => const FieldCrdt(lww: {'a': null}, sets: {'a'}).validate(),
          throwsArgumentError);
    });

    test('rejects unsafe names', () {
      expect(() => const FieldCrdt(lww: {'a;DROP': null}).validate(),
          throwsArgumentError);
      expect(
          () => const FieldCrdt(maps: {
                'm': FieldMap(fields: {'a b': null})
              }).validate(),
          throwsArgumentError);
    });

    test('rejects passive names that do not exist', () {
      expect(() => const FieldCrdt(passive: {'nope'}).validate(),
          throwsArgumentError);
    });

    test('fingerprints differ when the schema does', () {
      expect(const FieldCrdt(lww: {'a': null}).fingerprint,
          isNot(const FieldCrdt(lww: {'a': 0}).fingerprint));
      expect(const FieldCrdt(sets: {'a', 'b'}).fingerprint,
          const FieldCrdt(sets: {'b', 'a'}).fingerprint);
    });
  });

  group('merge laws', () {
    final nodes = ['A', 'B', 'C'];
    var clock = 0;

    FieldDoc randomDoc(Random rng, {bool allowDelete = false}) {
      final node = nodes[rng.nextInt(nodes.length)];
      Hlc stamp() => at(++clock, node);
      final base = stamp();
      if (allowDelete && rng.nextInt(4) == 0) {
        return FieldDoc(
            row: null,
            deleted: true,
            hlc: base,
            base: base,
            stamps: const {},
            marks: const {},
            heads: {node: base});
      }
      final stamps = <String, Hlc>{};
      final marks = <String, List<SetMark>>{};
      final row = <String, dynamic>{};
      if (rng.nextBool()) {
        row['entry'] = 'e${rng.nextInt(3)}';
        row['original'] = 'o${rng.nextInt(3)}';
        if (rng.nextBool()) stamps['@source'] = stamp();
      }
      if (rng.nextBool()) {
        row['note'] = rng.nextBool() ? 'n${rng.nextInt(4)}' : null;
        if (rng.nextBool()) stamps['note'] = stamp();
      }
      final eps = <String, dynamic>{};
      for (var i = 0; i < 4; i++) {
        final key = 'e$i';
        if (rng.nextBool()) {
          eps[key] = ep(
            bookmark: rng.nextBool(),
            finished: true,
            progress: rng.nextBool() ? '${rng.nextInt(3)}' : null,
          );
        }
        if (rng.nextInt(3) == 0) {
          stamps['episodedata/$key/bookmark'] = stamp();
        }
      }
      row['episodedata'] = eps;
      final set = <Object>[];
      final setMarks = <SetMark>[];
      for (final value in ['x', 'y', 'z']) {
        final roll = rng.nextInt(4);
        if (roll == 0) set.add(value);
        if (roll == 1) {
          set.add(value);
          setMarks.add(SetMark(value, stamp(), true));
        }
        if (roll == 2) setMarks.add(SetMark(value, stamp(), false));
      }
      row['categories'] = set;
      if (setMarks.isNotEmpty) marks['categories'] = setMarks;
      return FieldDoc(
        row: _recompute(row),
        deleted: false,
        hlc: stamp(),
        base: base,
        stamps: stamps,
        marks: marks,
        heads: {node: at(clock, node)},
      );
    }

    String form(FieldDoc d) => canonicalJson(d.toWire());

    test('merging is commutative and idempotent', () {
      final rng = Random(1);
      for (var i = 0; i < 2000; i++) {
        final a = randomDoc(rng, allowDelete: true);
        final b = randomDoc(rng, allowDelete: true);
        final ab = mergeFieldDocs(_schema, a, b);
        expect(form(ab), form(mergeFieldDocs(_schema, b, a)),
            reason: 'iteration $i');
        expect(form(mergeFieldDocs(_schema, ab, ab)), form(ab),
            reason: 'iteration $i');
      }
    });

    test('merging live rows is associative', () {
      final rng = Random(2);
      for (var i = 0; i < 2000; i++) {
        final a = randomDoc(rng);
        final b = randomDoc(rng);
        final c = randomDoc(rng);
        final left = mergeFieldDocs(_schema, mergeFieldDocs(_schema, a, b), c);
        final right = mergeFieldDocs(_schema, a, mergeFieldDocs(_schema, b, c));
        expect(canonicalJson(left.row), canonicalJson(right.row),
            reason: 'iteration $i');
      }
    });
  });
}
