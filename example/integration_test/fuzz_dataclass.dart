import 'dart:math';
import 'dart:typed_data';

import 'package:metis/metis.dart';
import 'package:uuid/uuid.dart';

class FuzzRng {
  final int seed;
  final Random _r;

  FuzzRng(this.seed) : _r = Random(seed);

  bool nextBool() => _r.nextBool();
  int nextInt(int max) => _r.nextInt(max);
  double nextDouble() => _r.nextDouble();

  int nextSmallInt() => _r.nextInt(1000000);

  DateTime nextDateTime() {
    // Pick an instant in the last ~20 years. Microsecond resolution is kept so distinct draws almost never collide (the CRDT uses these as field values, not as HLC timestamps, so collisions are non-fatal anyway).
    final micros =
        DateTime.utc(2010, 1, 1).microsecondsSinceEpoch + _r.nextInt(20 * 365);
    return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  Duration nextDuration() {
    // Random.nextInt max is 2^32, so generate microseconds in two draws.
    final micros = _r.nextInt(1 << 16) * (_r.nextInt(1 << 16) + 1);
    return Duration(microseconds: micros);
  }

  UuidValue nextUuid() => const Uuid().v4obj();

  BigInt nextBigInt() => BigInt.from(_r.nextInt(1 << 30)) * BigInt.from(7919);

  Uint8List nextBytes() {
    final len = _r.nextInt(64) + 1;
    final out = Uint8List(len);
    for (int i = 0; i < len; i++) {
      out[i] = _r.nextInt(256);
    }
    return out;
  }

  String nextString() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789_ ';
    final len = _r.nextInt(16);
    final codeUnits = <int>[];
    for (int i = 0; i < len; i++) {
      codeUnits.add(alphabet.codeUnitAt(_r.nextInt(alphabet.length)));
    }
    return String.fromCharCodes(codeUnits);
  }

  T nextElement<T>(List<T> items) => items[_r.nextInt(items.length)];
}

class FuzzRecord {
  final bool boolField;
  final int intField;
  final double doubleField;
  final String stringField;
  final DateTime? dateTimeField;
  final Duration? durationField;
  final UuidValue? uuidField;
  final BigInt? bigIntField;
  final Uint8List? bytesField;
  final List<dynamic> listField;
  final Map<String, dynamic> mapField;
  final DBRecord? relationField;

  FuzzRecord({
    required this.boolField,
    required this.intField,
    required this.doubleField,
    required this.stringField,
    required this.dateTimeField,
    required this.durationField,
    required this.uuidField,
    required this.bigIntField,
    required this.bytesField,
    required this.listField,
    required this.mapField,
    required this.relationField,
  });

  /// Build a random record. When [allowNulls] is true, the optional native-type
  /// fields are randomly null, which exercises the "A deletes, C modifies after
  /// B re-inserts" resurrection path at the field level.
  factory FuzzRecord.random(
    FuzzRng rng, {
    bool allowNulls = true,
    DBRecord? relation,
  }) {
    DateTime? dt;
    if (!allowNulls || !rng.nextBool()) dt = rng.nextDateTime();
    Duration? dur;
    if (!allowNulls || !rng.nextBool()) dur = rng.nextDuration();
    UuidValue? uuid;
    if (!allowNulls || !rng.nextBool()) uuid = rng.nextUuid();
    BigInt? big;
    if (!allowNulls || !rng.nextBool()) big = rng.nextBigInt();
    Uint8List? bytes;
    if (!allowNulls || !rng.nextBool()) bytes = rng.nextBytes();

    return FuzzRecord(
      boolField: rng.nextBool(),
      intField: rng.nextSmallInt(),
      doubleField: rng.nextDouble() * 1e6,
      stringField: rng.nextString(),
      dateTimeField: dt,
      durationField: dur,
      uuidField: uuid,
      bigIntField: big,
      bytesField: bytes,
      listField: [
        rng.nextSmallInt(),
        rng.nextString(),
        rng.nextBool(),
      ],
      mapField: {
        'a': rng.nextSmallInt(),
        'b': rng.nextString(),
        'c': rng.nextBool(),
      },
      relationField: relation,
    );
  }

  /// Map payload written to SurrealDB. The `id` is supplied by the caller (the
  /// record id) and is intentionally excluded so it doesn't leak into the
  /// comparison.
  Map<String, dynamic> toMap() => {
        'boolField': boolField,
        'intField': intField,
        'doubleField': doubleField,
        'stringField': stringField,
        'dateTimeField': dateTimeField,
        'durationField': durationField,
        'uuidField': uuidField,
        'bigIntField': bigIntField,
        'bytesField': bytesField,
        'listField': listField,
        'mapField': mapField,
        'relationField': relationField,
      };

  /// Reconstruct a record from a row read back from SurrealDB, dropping the
  /// `id` column. Returns null if [row] is missing required fields.
  static FuzzRecord? fromMap(Map<String, dynamic> row) {
    if (!row.containsKey('boolField')) return null;
    final relation = row['relationField'];
    return FuzzRecord(
      boolField: row['boolField'] as bool,
      intField: row['intField'] as int,
      doubleField: (row['doubleField'] as num).toDouble(),
      stringField: row['stringField'] as String,
      dateTimeField: row['dateTimeField'] as DateTime?,
      durationField: row['durationField'] as Duration?,
      uuidField: row['uuidField'] as UuidValue?,
      bigIntField: row['bigIntField'] is BigInt
          ? row['bigIntField'] as BigInt
          : (row['bigIntField'] == null
              ? null
              : BigInt.from(row['bigIntField'] as num)),
      bytesField: row['bytesField'] == null
          ? null
          : Uint8List.fromList((row['bytesField'] as List).cast<int>()),
      listField: List<dynamic>.from(row['listField'] as List? ?? const []),
      mapField:
          Map<String, dynamic>.from(row['mapField'] as Map? ?? const {}),
      relationField: relation is DBRecord ? relation : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FuzzRecord && _normalizedEquals(other);

  bool _normalizedEquals(FuzzRecord other) {
    if (boolField != other.boolField) return false;
    if (intField != other.intField) return false;
    if ((_normalDouble(doubleField) - _normalDouble(other.doubleField))
            .abs() >
        1e-9) {
      return false;
    }
    if (stringField != other.stringField) return false;
    if (!_dtEq(dateTimeField, other.dateTimeField)) return false;
    if (!_durEq(durationField, other.durationField)) return false;
    if (!_uuidEq(uuidField, other.uuidField)) return false;
    if (!_bigEq(bigIntField, other.bigIntField)) return false;
    if (!_bytesEq(bytesField, other.bytesField)) return false;
    if (!_listEq(listField, other.listField)) return false;
    if (!_mapEq(mapField, other.mapField)) return false;
    if (relationField != other.relationField) return false;
    return true;
  }

  static double _normalDouble(double v) => v == 0 ? 0.0 : v; // collapse -0.0
  static bool _dtEq(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.toUtc().microsecondsSinceEpoch == b.toUtc().microsecondsSinceEpoch;
  }

  static bool _durEq(Duration? a, Duration? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.inMicroseconds == b.inMicroseconds;
  }

  static bool _uuidEq(UuidValue? a, UuidValue? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.uuid.toLowerCase() == b.uuid.toLowerCase();
  }

  static bool _bigEq(BigInt? a, BigInt? b) {
    if (a == null || b == null) return a == null && b == null;
    return a.toString() == b.toString();
  }

  static bool _bytesEq(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == null && b == null;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listEq(List<dynamic> a, List<dynamic> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x is num && y is num) {
        if ((x - y).abs() > 1e-9) return false;
      } else if (x != y) {
        return false;
      }
    }
    return true;
  }

  static bool _mapEq(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      final x = a[key], y = b[key];
      if (x is num && y is num) {
        if ((x - y).abs() > 1e-9) return false;
      } else if (x != y) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      boolField.hashCode ^
      intField.hashCode ^
      stringField.hashCode ^
      relationField.hashCode;

  @override
  String toString() => 'FuzzRecord(${toMap()})';
}
