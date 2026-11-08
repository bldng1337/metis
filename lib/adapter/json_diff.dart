import 'package:flutter_surrealdb/flutter_surrealdb.dart';

/// Deep equality for database values. Records compare by content, since a
/// [DBRecord]'s `==` is shallow for array ids.
bool jsonValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!jsonValueEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is DBRecord && b is DBRecord) {
    return a.tb == b.tb && jsonValueEquals(a.id, b.id);
  }
  return a == b;
}

/// Copies maps and lists; leaf values are immutable.
T deepCopyJson<T>(T value) {
  final Object? copy = switch (value) {
    final Map<String, dynamic> map => <String, dynamic>{
        for (final entry in map.entries) entry.key: deepCopyJson(entry.value),
      },
    final Map<dynamic, dynamic> map => {
        for (final entry in map.entries) entry.key: deepCopyJson(entry.value),
      },
    final List<dynamic> list => [for (final item in list) deepCopyJson(item)],
    _ => value,
  };
  return copy as T;
}

String _escapeSegment(String key) =>
    key.replaceAll('~', '~0').replaceAll('/', '~1');

String _unescapeSegment(String token) =>
    token.replaceAll('~1', '/').replaceAll('~0', '~');

List<String> _pointerTokens(String pointer) =>
    pointer.isEmpty ? const [] : pointer.split('/').skip(1).toList();

/// Returns JSON patch ops turning [before] into [after]. Descends into maps;
/// lists are replaced whole, so ops stay valid against a row that changed
/// elsewhere in the meantime.
List<Map<String, dynamic>> diffJson(
    Map<String, dynamic> before, Map<String, dynamic> after) {
  final ops = <Map<String, dynamic>>[];
  _diffMaps(before, after, '', ops);
  return ops;
}

void _diffMaps(Map<dynamic, dynamic> before, Map<dynamic, dynamic> after,
    String path, List<Map<String, dynamic>> ops) {
  for (final key in before.keys) {
    if (!after.containsKey(key)) {
      ops.add({'op': 'remove', 'path': '$path/${_escapeSegment('$key')}'});
    }
  }
  for (final entry in after.entries) {
    final next = '$path/${_escapeSegment('${entry.key}')}';
    if (!before.containsKey(entry.key)) {
      ops.add({'op': 'add', 'path': next, 'value': entry.value});
      continue;
    }
    final old = before[entry.key];
    if (old is Map && entry.value is Map) {
      _diffMaps(old, entry.value as Map, next, ops);
    } else if (!jsonValueEquals(old, entry.value)) {
      ops.add({'op': 'replace', 'path': next, 'value': entry.value});
    }
  }
}

/// Applies add/replace/remove [ops] to [doc] in place. Ops addressing paths
/// that do not exist are skipped: a row can hold fields its class ignores.
void applyJsonOps(Map<String, dynamic> doc, List<Map<String, dynamic>> ops) {
  for (final op in ops) {
    final path = op['path'];
    if (path is! String) continue;
    final tokens = _pointerTokens(path);
    if (tokens.isEmpty) {
      final value = op['value'];
      if (value is Map) {
        doc
          ..clear()
          ..addAll(deepCopyJson(value.cast<String, dynamic>()));
      }
      continue;
    }
    Object? parent = doc;
    for (final token in tokens.take(tokens.length - 1)) {
      parent = _child(parent, token);
    }
    _applyAt(parent, tokens.last, op['op'], deepCopyJson(op['value']));
  }
}

Object? _child(Object? parent, String token) {
  if (parent is Map) return parent[_unescapeSegment(token)];
  if (parent is List) {
    final index = int.tryParse(token);
    if (index != null && index >= 0 && index < parent.length) {
      return parent[index];
    }
  }
  return null;
}

void _applyAt(Object? parent, String token, Object? op, Object? value) {
  if (parent is Map) {
    final key = _unescapeSegment(token);
    if (op == 'remove') {
      parent.remove(key);
    } else {
      parent[key] = value;
    }
    return;
  }
  if (parent is! List) return;
  final index = token == '-' ? parent.length : int.tryParse(token);
  if (index == null || index < 0 || index > parent.length) return;
  if (op == 'remove') {
    if (index < parent.length) parent.removeAt(index);
  } else if (index == parent.length) {
    parent.add(value);
  } else if (op == 'add') {
    parent.insert(index, value);
  } else {
    parent[index] = value;
  }
}

/// Reads the value at a JSON [pointer], or null when it does not exist.
Object? readJsonPointer(Object? doc, String pointer) {
  Object? current = doc;
  for (final token in _pointerTokens(pointer)) {
    current = _child(current, token);
  }
  return current;
}

/// A stable text form of [value]: equal values give equal strings regardless
/// of map key order.
String canonicalJson(Object? value) {
  final out = StringBuffer();
  _writeCanonical(value, out);
  return out.toString();
}

void _writeCanonical(Object? value, StringBuffer out) {
  switch (value) {
    case final Map<dynamic, dynamic> map:
      final keys = map.keys.map((e) => '$e').toList()..sort();
      out.write('{');
      for (final (i, key) in keys.indexed) {
        if (i > 0) out.write(',');
        out
          ..write(_quote(key))
          ..write(':');
        _writeCanonical(map[key], out);
      }
      out.write('}');
    case final List<dynamic> list:
      out.write('[');
      for (final (i, item) in list.indexed) {
        if (i > 0) out.write(',');
        _writeCanonical(item, out);
      }
      out.write(']');
    case final DateTime date:
      out.write(_quote(date.toUtc().toIso8601String()));
    case final DBRecord record:
      out
        ..write(_quote(record.tb))
        ..write('#');
      _writeCanonical(record.id, out);
    case final String text:
      out.write(_quote(text));
    default:
      out.write('$value');
  }
}

String _quote(String text) =>
    '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
