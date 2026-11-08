import 'package:flutter_surrealdb/flutter_surrealdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/json_diff.dart';

void main() {
  group('diffJson', () {
    test('finds nothing between equal documents', () {
      final doc = {
        'a': 1,
        'b': {
          'c': [
            1,
            {'d': 2}
          ]
        }
      };
      expect(diffJson(doc, deepCopyJson(doc)), isEmpty);
    });

    test('descends maps and addresses only the changed leaf', () {
      final ops = diffJson({
        'keep': {'x': 1},
        'm': {'a': 1, 'b': 2},
      }, {
        'keep': {'x': 1},
        'm': {'a': 1, 'b': 3},
      });
      expect(ops, [
        {'op': 'replace', 'path': '/m/b', 'value': 3}
      ]);
    });

    test('reports additions and removals', () {
      final ops = diffJson({'gone': 1, 'm': <String, dynamic>{}}, {
        'm': {'new': 2}
      });
      expect(
          ops,
          containsAll([
            {'op': 'remove', 'path': '/gone'},
            {'op': 'add', 'path': '/m/new', 'value': 2},
          ]));
    });

    test('replaces lists whole', () {
      expect(
          diffJson({
            'l': [1, 2]
          }, {
            'l': [1, 3]
          }),
          [
            {
              'op': 'replace',
              'path': '/l',
              'value': [1, 3]
            }
          ]);
    });

    test('escapes keys holding pointer syntax', () {
      expect(diffJson({'m': <String, dynamic>{}}, {
        'm': {'a/b~c': 1}
      }).single['path'], '/m/a~1b~0c');
    });

    test('treats array record ids by content', () {
      expect(
          diffJson({
            'r': const DBRecord('t', ['a', 1])
          }, {
            'r': const DBRecord('t', ['a', 1])
          }),
          isEmpty);
    });
  });

  group('applyJsonOps', () {
    test('round trips a diff', () {
      final before = <String, dynamic>{
        'a': 1,
        'm': {'x/y': 1, 'z': 2},
        'l': [1, 2],
      };
      final after = <String, dynamic>{
        'b': 2,
        'm': {'x/y': 9, 'new': true},
        'l': [3],
      };
      final doc = deepCopyJson(before);
      applyJsonOps(doc, diffJson(before, after));
      expect(doc, after);
    });

    test('applies array index ops in sequence', () {
      final doc = <String, dynamic>{
        'l': [1, 2, 3]
      };
      applyJsonOps(doc, [
        {'op': 'replace', 'path': '/l/0', 'value': 9},
        {'op': 'remove', 'path': '/l/2'},
        {'op': 'add', 'path': '/l/-', 'value': 7},
      ]);
      expect(doc['l'], [9, 2, 7]);
    });

    test('replaces the whole document on an empty path', () {
      final doc = <String, dynamic>{'a': 1};
      applyJsonOps(doc, [
        {
          'op': 'replace',
          'path': '',
          'value': {'b': 2}
        }
      ]);
      expect(doc, {'b': 2});
    });

    test('skips ops through missing parents', () {
      final doc = <String, dynamic>{'a': 1};
      applyJsonOps(doc, [
        {'op': 'replace', 'path': '/missing/deep', 'value': 1},
        {'op': 'remove', 'path': '/l/4'},
      ]);
      expect(doc, {'a': 1});
    });

    test('does not alias op values', () {
      final value = <String, dynamic>{'x': 1};
      final doc = <String, dynamic>{};
      applyJsonOps(doc, [
        {'op': 'add', 'path': '/a', 'value': value}
      ]);
      value['x'] = 2;
      expect(doc['a'], {'x': 1});
    });
  });

  test('readJsonPointer resolves escaped paths', () {
    expect(
        readJsonPointer({
          'm': {'a/b': 5}
        }, '/m/a~1b'),
        5);
    expect(readJsonPointer({'m': 1}, '/n/o'), isNull);
  });

  test('canonicalJson ignores key order but not values', () {
    expect(canonicalJson({'a': 1, 'b': 2}), canonicalJson({'b': 2, 'a': 1}));
    expect(canonicalJson({'a': 1}), isNot(canonicalJson({'a': 2})));
    expect(canonicalJson(['1']), isNot(canonicalJson([1])));
    expect(canonicalJson(const DBRecord('t', 'x')),
        canonicalJson(const DBRecord('t', 'x')));
  });
}
