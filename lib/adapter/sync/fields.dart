import 'dart:convert';

import 'package:crdt/crdt.dart';
import 'package:metis/adapter/json_diff.dart';

final _namePattern = RegExp(r'^[a-zA-Z0-9_]+$');

const _restGroup = '@rest';
String _groupPath(String name) => '@$name';

/// Declares which parts of a row merge independently during sync.
///
/// Fields not mentioned anywhere share one implicit group, so an undeclared
/// field behaves like whole-row last-write-wins.
class FieldCrdt {
  /// Named sets of fields that share one stamp and are copied together.
  final Map<String, List<String>> groups;

  /// Group names or [lww] fields whose changes do not keep a deleted row
  /// alive, for machine-made changes like a background refresh.
  final Set<String> passive;

  /// Fields merged individually by last-write-wins, with their default. A
  /// missing value and the default count as the same value.
  final Map<String, Object?> lww;

  /// Fields stored as objects whose entries merge per key and per field.
  final Map<String, FieldMap> maps;

  /// List fields merged per element. An element's identity is its whole
  /// value, and the merged list is sorted by that value.
  final Set<String> sets;

  /// Fields computed from the rest of the row: never stamped, never compared.
  final Set<String> derived;

  /// Rebuilds [derived] fields on a merged row. Runs inside the sync
  /// transaction, also on the serving side, so it must be pure.
  final Map<String, dynamic> Function(Map<String, dynamic> row)? recompute;

  const FieldCrdt({
    this.groups = const {},
    this.passive = const {},
    this.lww = const {},
    this.maps = const {},
    this.sets = const {},
    this.derived = const {},
    this.recompute,
  });

  Iterable<String> get _groupFields => groups.values.expand((e) => e);

  Set<String> get knownFields => {
        ..._groupFields,
        ...lww.keys,
        ...maps.keys,
        ...sets,
        ...derived,
      };

  void validate() {
    void name(String value, String what) {
      if (!_namePattern.hasMatch(value)) {
        throw ArgumentError.value(value, what,
            'must be a valid identifier (alphanumeric and underscore only)');
      }
    }

    final seen = <String>{};
    for (final field in [
      ..._groupFields,
      ...lww.keys,
      ...maps.keys,
      ...sets,
      ...derived,
    ]) {
      name(field, 'field');
      if (!seen.add(field)) {
        throw ArgumentError.value(field, 'field', 'is declared more than once');
      }
    }
    if (seen.contains('id')) {
      throw ArgumentError.value('id', 'field', 'cannot be declared');
    }
    for (final group in groups.keys) {
      name(group, 'group');
    }
    for (final entry in maps.entries) {
      final map = entry.value;
      for (final field in [...map.fields.keys, ...map.sets]) {
        name(field, 'field of ${entry.key}');
      }
      if (map.fields.keys.toSet().intersection(map.sets).isNotEmpty) {
        throw ArgumentError.value(
            entry.key, 'maps', 'a field cannot be both a value and a set');
      }
    }
    for (final item in passive) {
      if (!groups.containsKey(item) && !lww.containsKey(item)) {
        throw ArgumentError.value(
            item, 'passive', 'must name a group or an lww field');
      }
    }
  }

  /// Identifies the schema; peers must agree on it to sync.
  String get fingerprint => canonicalJson({
        'groups': groups,
        'passive': passive.toList()..sort(),
        'lww': lww,
        'maps': {
          for (final entry in maps.entries)
            entry.key: {
              'fields': entry.value.fields,
              'sets': entry.value.sets.toList()..sort(),
            },
        },
        'sets': sets.toList()..sort(),
        'derived': derived.toList()..sort(),
      });

  bool _isPassive(String path) => passive.any(
      (item) => path == item || (path == _groupPath(item)));
}

/// The entries of a [FieldCrdt.maps] field.
class FieldMap {
  /// Per-entry fields with their defaults. An entry whose fields are all
  /// default and whose sets are empty is dropped from the row.
  final Map<String, Object?> fields;

  /// Per-entry list fields merged per element.
  final Set<String> sets;

  const FieldMap({required this.fields, this.sets = const {}});
}

/// Whether one replica's view of a row has seen the other's writes.
enum SyncOrder { older, same, newer, concurrent }

SyncOrder compareHeads(Map<String, Hlc> a, Map<String, Hlc> b) {
  var aAhead = false;
  var bAhead = false;
  for (final node in {...a.keys, ...b.keys}) {
    final order = _compareStamps(a[node], b[node]);
    if (order > 0) aAhead = true;
    if (order < 0) bAhead = true;
  }
  if (aAhead && bAhead) return SyncOrder.concurrent;
  if (aAhead) return SyncOrder.newer;
  if (bAhead) return SyncOrder.older;
  return SyncOrder.same;
}

int _compareStamps(Hlc? a, Hlc? b) {
  if (a == null) return b == null ? 0 : -1;
  if (b == null) return 1;
  return a.compareTo(b).sign;
}

Hlc _maxStamp(Hlc a, Hlc b) => a.compareTo(b) >= 0 ? a : b;

Map<String, Hlc> joinHeads(Map<String, Hlc> a, Map<String, Hlc> b) => {
      ...a,
      for (final entry in b.entries)
        entry.key: a.containsKey(entry.key)
            ? _maxStamp(a[entry.key]!, entry.value)
            : entry.value,
    };

/// One changed element of a set: [present] is false for a removal.
class SetMark {
  final Object? value;
  final Hlc stamp;
  final bool present;

  const SetMark(this.value, this.stamp, this.present);
}

/// A row together with its field stamps.
///
/// A path without a stamp was last written at [base], except that a default
/// value without a stamp counts as never written.
class FieldDoc {
  static const _wireTag = '__metis_field_doc__';

  final Map<String, dynamic>? row;
  final bool deleted;
  final Hlc hlc;
  final Hlc base;
  final Map<String, Hlc> stamps;
  final Map<String, List<SetMark>> marks;
  final Map<String, Hlc> heads;

  const FieldDoc({
    required this.row,
    required this.deleted,
    required this.hlc,
    required this.base,
    required this.stamps,
    required this.marks,
    required this.heads,
  });

  FieldDoc withHeads(Map<String, Hlc> value) => FieldDoc(
      row: row,
      deleted: deleted,
      hlc: hlc,
      base: base,
      stamps: stamps,
      marks: marks,
      heads: value);

  static bool isWire(Object? data) => data is Map && data[_wireTag] == 1;

  Map<String, dynamic> toWire() => {
        _wireTag: 1,
        'row': row,
        'deleted': deleted,
        'hlc': hlc.toString(),
        'base': base.toString(),
        'heads': {for (final e in heads.entries) e.key: e.value.toString()},
        'stamps': {for (final e in stamps.entries) e.key: e.value.toString()},
        'marks': {
          for (final e in marks.entries)
            e.key: [
              for (final mark in e.value)
                {'v': mark.value, 's': mark.stamp.toString(), 'a': mark.present}
            ],
        },
      };

  factory FieldDoc.fromWire(Map<String, dynamic> json) {
    Map<String, Hlc> hlcs(Object? raw) => {
          for (final e in (raw as Map).entries)
            e.key as String: Hlc.parse(e.value as String),
        };
    return FieldDoc(
      row: (json['row'] as Map?)?.cast<String, dynamic>(),
      deleted: json['deleted'] as bool,
      hlc: Hlc.parse(json['hlc'] as String),
      base: Hlc.parse(json['base'] as String),
      heads: hlcs(json['heads']),
      stamps: hlcs(json['stamps']),
      marks: {
        for (final e in (json['marks'] as Map).entries)
          e.key as String: [
            for (final mark in e.value as List)
              SetMark(mark['v'], Hlc.parse(mark['s'] as String),
                  mark['a'] as bool),
          ],
      },
    );
  }

  /// Decodes a stamp stored as `[timestamp, count, node]`.
  static Hlc stampFromDB(Object? raw) {
    final parts = raw as List;
    return Hlc(parts[0] as DateTime, parts[1] as int, parts[2] as String);
  }

  static List<Object> stampToDB(Hlc stamp) =>
      [stamp.dateTime, stamp.counter, stamp.nodeId];

  /// The sidecar row holding [base] and the per-path stamps.
  Map<String, dynamic> sidecarToDB() => {
        'base': stampToDB(base),
        'fields': {
          for (final e in stamps.entries) e.key: stampToDB(e.value),
          for (final e in marks.entries)
            e.key: [
              for (final mark in e.value)
                {'v': mark.value, 's': stampToDB(mark.stamp), 'a': mark.present}
            ],
        },
      };

  /// Splits the sidecar's `fields` object into stamps and set marks.
  static (Map<String, Hlc>, Map<String, List<SetMark>>) parseFields(
      Map<dynamic, dynamic>? fields) {
    final stamps = <String, Hlc>{};
    final marks = <String, List<SetMark>>{};
    for (final entry in (fields ?? const {}).entries) {
      final value = entry.value as List;
      if (value.isNotEmpty && value.first is DateTime) {
        stamps[entry.key as String] = stampFromDB(value);
      } else {
        marks[entry.key as String] = [
          for (final mark in value)
            SetMark(mark['v'], stampFromDB(mark['s']), mark['a'] as bool),
        ];
      }
    }
    return (stamps, marks);
  }

  Hlc _intent(FieldCrdt schema) {
    var newest = base;
    for (final entry in stamps.entries) {
      if (!schema._isPassive(entry.key)) {
        newest = _maxStamp(newest, entry.value);
      }
    }
    for (final list in marks.values) {
      for (final mark in list) {
        newest = _maxStamp(newest, mark.stamp);
      }
    }
    return newest;
  }
}

/// Merges two views of a row. Commutative, associative and idempotent, so
/// replicas converge whatever order they exchange state in.
FieldDoc mergeFieldDocs(FieldCrdt schema, FieldDoc a, FieldDoc b) {
  final heads = joinHeads(a.heads, b.heads);
  if (a.deleted && b.deleted) {
    return (a.hlc.compareTo(b.hlc) >= 0 ? a : b).withHeads(heads);
  }
  if (a.deleted || b.deleted) {
    final tomb = a.deleted ? a : b;
    final live = a.deleted ? b : a;
    final survives = live._intent(schema).compareTo(tomb.hlc) > 0;
    return (survives ? live : tomb).withHeads(heads);
  }
  return _Merger(schema, a, b, heads).run();
}

class _Merger {
  final FieldCrdt schema;
  final FieldDoc a;
  final FieldDoc b;
  final Map<String, Hlc> heads;
  final Map<String, dynamic> rowA;
  final Map<String, dynamic> rowB;
  final Hlc base;

  final out = <String, dynamic>{};
  final stamps = <String, Hlc>{};
  final marks = <String, List<SetMark>>{};

  _Merger(this.schema, this.a, this.b, this.heads)
      : rowA = a.row!,
        rowB = b.row!,
        base = _maxStamp(a.base, b.base);

  FieldDoc run() {
    final known = schema.knownFields;
    schema.groups.forEach((name, fields) {
      _group(_groupPath(name), fields);
    });
    _group(_restGroup, {
      ...rowA.keys,
      ...rowB.keys,
    }.where((key) => key != 'id' && !known.contains(key)).toList());
    schema.lww.forEach(_lww);
    schema.maps.forEach(_map);
    for (final field in schema.sets) {
      if (!rowA.containsKey(field) && !rowB.containsKey(field)) continue;
      out[field] = _set(field, rowA[field], rowB[field]);
    }
    _derived();
    final recompute = schema.recompute;
    return FieldDoc(
      row: recompute == null ? out : recompute(out),
      deleted: false,
      hlc: _maxStamp(a.hlc, b.hlc),
      base: base,
      stamps: stamps,
      marks: marks,
      heads: heads,
    );
  }

  /// True when side A wins [path]; records the winning stamp.
  bool _resolve(String path, Object? valueA, Object? valueB,
      {bool hasDefault = false, Object? fallback}) {
    bool implicitNever(Object? value) =>
        hasDefault && jsonValueEquals(value ?? fallback, fallback);
    final explicitA = a.stamps[path];
    final explicitB = b.stamps[path];
    final stampA = explicitA ?? (implicitNever(valueA) ? null : a.base);
    final stampB = explicitB ?? (implicitNever(valueB) ? null : b.base);
    var order = _compareStamps(stampA, stampB);
    if (order == 0 && !jsonValueEquals(valueA, valueB)) {
      order = canonicalJson(valueA).compareTo(canonicalJson(valueB));
    }
    final aWins = order >= 0;
    final winner = aWins ? stampA : stampB;
    final explicit = aWins ? explicitA : explicitB;
    if (winner != null && (explicit != null || winner != base)) {
      stamps[path] = winner;
    }
    return aWins;
  }

  void _group(String path, List<String> fields) {
    Map<String, dynamic> pick(Map<String, dynamic> row) => {
          for (final field in fields)
            if (row.containsKey(field)) field: row[field],
        };
    final valueA = pick(rowA);
    final valueB = pick(rowB);
    if (valueA.isEmpty && valueB.isEmpty) return;
    out.addAll(_resolve(path, valueA, valueB) ? valueA : valueB);
  }

  void _lww(String field, Object? fallback) {
    if (!rowA.containsKey(field) && !rowB.containsKey(field)) return;
    final aWins = _resolve(field, rowA[field], rowB[field],
        hasDefault: true, fallback: fallback);
    out[field] = (aWins ? rowA[field] : rowB[field]) ?? fallback;
  }

  void _map(String field, FieldMap spec) {
    final hasA = rowA[field] is Map;
    final hasB = rowB[field] is Map;
    final mapA = hasA ? rowA[field] as Map : const {};
    final mapB = hasB ? rowB[field] as Map : const {};
    final prefix = '$field/';
    final keys = <String>{
      ...mapA.keys.cast<String>(),
      ...mapB.keys.cast<String>(),
    };
    void addStamped(Iterable<String> paths) {
      for (final path in paths) {
        if (!path.startsWith(prefix)) continue;
        final end = path.lastIndexOf('/');
        if (end > prefix.length - 1) keys.add(path.substring(prefix.length, end));
      }
    }

    addStamped(a.stamps.keys);
    addStamped(b.stamps.keys);
    addStamped(a.marks.keys);
    addStamped(b.marks.keys);
    if (keys.isEmpty && !hasA && !hasB) return;

    final extrasA = a.hlc.compareTo(b.hlc) >= 0;
    final merged = <String, dynamic>{};
    for (final key in keys) {
      final itemA = mapA[key] as Map? ?? const {};
      final itemB = mapB[key] as Map? ?? const {};
      final item = <String, dynamic>{
        for (final entry in (extrasA ? itemB : itemA).entries)
          entry.key as String: entry.value,
        for (final entry in (extrasA ? itemA : itemB).entries)
          entry.key as String: entry.value,
      };
      var empty = true;
      spec.fields.forEach((name, fallback) {
        final path = '$prefix$key/$name';
        final aWins = _resolve(path, itemA[name], itemB[name],
            hasDefault: true, fallback: fallback);
        final value = (aWins ? itemA[name] : itemB[name]) ?? fallback;
        item[name] = value;
        if (!jsonValueEquals(value, fallback)) empty = false;
      });
      for (final name in spec.sets) {
        final list = _set('$prefix$key/$name', itemA[name], itemB[name]);
        item[name] = list;
        if (list.isNotEmpty) empty = false;
      }
      if (!empty) merged[key] = item;
    }
    out[field] = merged;
  }

  List<dynamic> _set(String path, Object? listA, Object? listB) {
    final values = <String, Object?>{};
    final winners = <String, (Hlc, bool, bool)>{};

    void read(FieldDoc doc, Object? list) {
      final state = <String, (Hlc, bool, bool)>{};
      for (final value in (list as List?) ?? const []) {
        final key = canonicalJson(value);
        values[key] = value;
        state[key] = (doc.base, true, false);
      }
      for (final mark in doc.marks[path] ?? const <SetMark>[]) {
        final key = canonicalJson(mark.value);
        values[key] = mark.value;
        state[key] = (mark.stamp, mark.present, true);
      }
      state.forEach((key, next) {
        final current = winners[key];
        if (current == null) {
          winners[key] = next;
          return;
        }
        final order = current.$1.compareTo(next.$1);
        if (order < 0 || (order == 0 && next.$2 && !current.$2)) {
          winners[key] = next;
        }
      });
    }

    read(a, listA);
    read(b, listB);

    final keys = winners.keys.toList()..sort();
    final kept = <SetMark>[];
    final result = <dynamic>[];
    for (final key in keys) {
      final (stamp, present, explicit) = winners[key]!;
      if (present) result.add(values[key]);
      if (explicit || stamp != base) {
        kept.add(SetMark(values[key], stamp, present));
      }
    }
    if (kept.isNotEmpty) marks[path] = kept;
    return result;
  }

  void _derived() {
    final preferA = a.hlc.compareTo(b.hlc) >= 0;
    final first = preferA ? rowA : rowB;
    final second = preferA ? rowB : rowA;
    for (final field in schema.derived) {
      if (first.containsKey(field)) {
        out[field] = first[field];
      } else if (second.containsKey(field)) {
        out[field] = second[field];
      }
    }
  }
}

/// Builds the SurrealQL body of the sync event for a [FieldCrdt] table. It
/// avoids closures, which SurrealDB rejects inside event definitions.
String fieldEventBody(
  FieldCrdt schema, {
  required String crdtTable,
  required String fieldsTable,
  required String nodeId,
}) {
  final out = StringBuffer();
  void line(String text) => out.writeln(text);
  String quote(String text) => "'$text'";
  String literal(Object? value) => value == null ? 'NULL' : jsonEncode(value);

  line(r'IF $before == $after { RETURN NULL; };');
  line(r'LET $empty = {};');
  line(r'LET $b = $before ?? $empty;');
  line(r'LET $a = $after ?? $empty;');
  line('LET \$entry = type::record("$crdtTable",[record::tb(\$value.id),record::id(\$value.id)]);');
  line('LET \$sidekey = type::record("$fieldsTable",[record::tb(\$value.id),record::id(\$value.id)]);');
  line(r'LET $curr = SELECT * FROM ONLY $entry;');
  line(r'LET $side = SELECT * FROM ONLY $sidekey;');
  line(r'LET $deleted = $event == "DELETE";');
  line(r'LET $known = $curr != NONE;');
  line(r'LET $now = time::now();');
  line(r'LET $behind = $known AND $now <= $curr.timestamp;');
  line(r'LET $ts = IF $behind { $curr.timestamp } ELSE { $now };');
  line(r'LET $count = IF $behind { $curr.count + 1 } ELSE { 0 };');
  line('LET \$stamp = [\$ts, \$count, ${quote(nodeId)}];');
  line(r'LET $reset = $deleted OR !$known OR $curr.deleted;');

  final scalarVars = <String>[];
  final setChecks = <String>[];
  final setUpdates = StringBuffer();

  // Marks are appended one by one: selecting from a list of record links
  // would fetch the records.
  String setUpdate(String pathExpr, String before, String after) => '''
LET \$path = $pathExpr;
LET \$old = (SELECT VALUE fields FROM ONLY \$sidekey)[\$path] ?? [];
LET \$added = array::complement($after, $before);
LET \$removed = array::complement($before, $after);
LET \$changed = array::concat(\$added, \$removed);
LET \$kept = SELECT VALUE \$this FROM \$old WHERE \$this.v NOT IN \$changed;
UPDATE \$sidekey SET fields = object::extend(fields, object::from_entries([[\$path, \$kept]]));
FOR \$v IN \$added {
  LET \$list = array::append((SELECT VALUE fields FROM ONLY \$sidekey)[\$path], { v: \$v, s: \$stamp, a: true });
  UPDATE \$sidekey SET fields = object::extend(fields, object::from_entries([[\$path, \$list]]));
};
FOR \$v IN \$removed {
  LET \$list = array::append((SELECT VALUE fields FROM ONLY \$sidekey)[\$path], { v: \$v, s: \$stamp, a: false });
  UPDATE \$sidekey SET fields = object::extend(fields, object::from_entries([[\$path, \$list]]));
};
''';

  var index = 0;
  schema.groups.forEach((name, fields) {
    final variable = '\$g${index++}';
    final test = fields.map((f) => '\$b.$f != \$a.$f').join(' OR ');
    line('LET $variable = IF ${test.isEmpty ? 'false' : test} '
        "{ ['${_groupPath(name)}'] } ELSE { [] };");
    scalarVars.add(variable);
  });

  final known = (schema.knownFields.toList()..add('id')).map(quote).join(',');
  line('LET \$restKeys = array::complement('
      'array::union(object::keys(\$a), object::keys(\$b)), [$known]);');
  line(r'LET $restChanged = SELECT VALUE $this FROM $restKeys '
      r'WHERE $b[$this] != $a[$this];');
  line("LET \$rest = IF array::len(\$restChanged) > 0 "
      "{ ['$_restGroup'] } ELSE { [] };");
  scalarVars.add(r'$rest');

  index = 0;
  schema.lww.forEach((field, fallback) {
    final variable = '\$l${index++}';
    final d = literal(fallback);
    line('LET $variable = IF (\$b.$field ?? $d) != (\$a.$field ?? $d) '
        "{ ['$field'] } ELSE { [] };");
    scalarVars.add(variable);
  });

  var mapIndex = 0;
  schema.maps.forEach((field, spec) {
    final m = '\$m${mapIndex++}';
    line('LET ${m}b = \$b.$field ?? \$empty;');
    line('LET ${m}a = \$a.$field ?? \$empty;');
    line('LET ${m}keys = array::union(object::keys(${m}b), object::keys(${m}a));');
    line('LET ${m}ch = SELECT VALUE \$this FROM ${m}keys '
        'WHERE ${m}b[\$this] != ${m}a[\$this];');
    var i = 0;
    spec.fields.forEach((name, fallback) {
      final variable = '${m}f${i++}';
      final d = literal(fallback);
      line("LET $variable = SELECT VALUE string::concat('$field/', \$this, '/$name') "
          'FROM ${m}ch '
          'WHERE (${m}b[\$this].$name ?? $d) != (${m}a[\$this].$name ?? $d);');
      scalarVars.add(variable);
    });
    i = 0;
    for (final name in spec.sets) {
      final variable = '${m}s${i++}';
      line('LET $variable = SELECT VALUE \$this FROM ${m}ch '
          'WHERE (${m}b[\$this].$name ?? []) != (${m}a[\$this].$name ?? []);');
      setChecks.add('array::len($variable) > 0');
      setUpdates.writeln('FOR \$k IN $variable {');
      setUpdates.write(setUpdate(
        "string::concat('$field/', \$k, '/$name')",
        '(${m}b[\$k].$name ?? [])',
        '(${m}a[\$k].$name ?? [])',
      ));
      setUpdates.writeln('};');
    }
  });

  for (final field in schema.sets) {
    final before = '(\$b.$field ?? [])';
    final after = '(\$a.$field ?? [])';
    setChecks.add('$before != $after');
    setUpdates.writeln('IF $before != $after {');
    setUpdates.write(setUpdate(quote(field), before, after));
    setUpdates.writeln('};');
  }

  line('LET \$paths = array::flatten([${scalarVars.join(', ')}]);');
  final anyChange = ['array::len(\$paths) > 0', ...setChecks].join(' OR ');
  line('IF !\$reset AND !($anyChange) { RETURN NULL; };');
  line(r'LET $legacy = IF $known { [$curr.timestamp, $curr.count, $curr.node] } ELSE { $stamp };');
  line(r'LET $base = IF $reset { $stamp } ELSE { $side.base ?? $legacy };');
  line(r'LET $newFields = object::from_entries(SELECT VALUE [$this, $stamp] FROM $paths);');
  line(r'LET $fields = IF $reset { $empty } ELSE { object::extend($side.fields ?? $empty, $newFields) };');
  line(r'LET $oldHeads = IF $known { $curr.heads ?? object::from_entries([[$curr.node, $legacy]]) } ELSE { $empty };');
  line('LET \$heads = object::extend(\$oldHeads, object::from_entries([[${quote(nodeId)}, \$stamp]]));');
  line('UPSERT \$entry CONTENT { timestamp: \$ts, count: \$count, deleted: \$deleted, '
      'entry: \$value.id, node: ${quote(nodeId)}, heads: \$heads };');
  line(r'UPSERT $sidekey CONTENT { base: $base, fields: $fields };');
  if (setUpdates.isNotEmpty) {
    line('IF !\$reset {');
    out.write(setUpdates);
    line('};');
  }
  line('RETURN NULL;');
  return out.toString();
}
