import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metis/adapter/sync/repo.dart';
import 'package:metis/metis.dart';
import 'package:uuid/uuid.dart';

import '../integration_test/fuzz_dataclass.dart';

/// Verifies the pure-Dart logic of the fuzz machinery without needing the
/// SurrealDB native library (which currently fails to compile in this
/// environment due to an unrelated `half` crate / Rust toolchain issue).
///
/// The full end-to-end fuzz scenario lives in integration_test/fuzz_sync.dart.
void main() {
  group('serializer/reviver native type round-trip', () {
    dynamic roundTrip(Object? value) {
      // SyncHttpClient/SyncHttpServer move values through JSON using these two
      // hooks, so this is exactly the transport encoding.
      final encoded = jsonEncode(value, toEncodable: serializer);
      return jsonDecode(encoded, reviver: revive);
    }

    test('DateTime', () {
      final dt = DateTime.utc(2025, 7, 20, 12, 30, 45, 123, 456);
      final out = roundTrip(dt);
      expect(out, isA<DateTime>());
      expect((out as DateTime).toUtc(), dt.toUtc());
    });

    test('Duration', () {
      const d = Duration(hours: 3, minutes: 21, seconds: 9, microseconds: 7);
      final out = roundTrip(d);
      expect(out, isA<Duration>());
      expect(out as Duration, d);
    });

    test('UuidValue', () {
      final u = const Uuid().v4obj();
      final out = roundTrip(u);
      expect(out, isA<UuidValue>());
      expect((out as UuidValue).uuid.toLowerCase(), u.uuid.toLowerCase());
    });

    test('BigInt', () {
      final b = BigInt.parse('9223372036854775808'); // > int64
      final out = roundTrip(b);
      expect(out, isA<BigInt>());
      expect(out as BigInt, b);
    });

    test('Uint8List round-trips as List<int> (jsonEncode encodes it natively)',
        () {
      final bytes = Uint8List.fromList([0, 1, 2, 3, 255, 128, 0, 7]);
      final out = roundTrip(bytes);
      // dart:convert encodes Uint8List as a JSON array without invoking
      // toEncodable, so the reviver sees a plain List<int>. Consumers normalize
      // it back (see FuzzRecord.fromMap).
      expect(out, isA<List>());
      expect(Uint8List.fromList((out as List).cast<int>()), bytes);
    });

    test('DBRecord', () {
      const r = DBRecord('fuzz', 'rec3');
      final out = roundTrip(r);
      expect(out, isA<DBRecord>());
      expect(out as DBRecord, r);
    });

    test('nested map with all types', () {
      final value = <String, dynamic>{
        'dt': DateTime.utc(2024, 1, 2),
        'dur': const Duration(minutes: 5),
        'uuid': const Uuid().v4obj(),
        'big': BigInt.from(1 << 40),
        'bytes': Uint8List.fromList([1, 2, 3]),
        'rec': const DBRecord('fuzz', 'x'),
        'plain': 'string',
        'list': [
          DateTime.utc(2023, 3, 3),
          const DBRecord('fuzz', 'y'),
          42,
        ],
      };
      final out = roundTrip(value) as Map<String, dynamic>;
      expect(out['dt'], isA<DateTime>());
      expect(out['dur'], isA<Duration>());
      expect(out['uuid'], isA<UuidValue>());
      expect(out['big'], isA<BigInt>());
      expect(Uint8List.fromList((out['bytes'] as List).cast<int>()),
          Uint8List.fromList([1, 2, 3]));
      expect(out['rec'], const DBRecord('fuzz', 'x'));
      expect(out['plain'], 'string');
      expect((out['list'] as List)[0], isA<DateTime>());
      expect((out['list'] as List)[1], const DBRecord('fuzz', 'y'));
      expect((out['list'] as List)[2], 42);
    });
  });

  group('FuzzRng determinism', () {
    test('same seed reproduces the same sequence', () {
      final a = FuzzRng(42);
      final b = FuzzRng(42);
      for (int i = 0; i < 100; i++) {
        expect(a.nextInt(1000), b.nextInt(1000));
        expect(a.nextBool(), b.nextBool());
        expect(a.nextDouble(), b.nextDouble());
      }
    });

    test('different seeds diverge', () {
      final a = FuzzRng(1);
      final b = FuzzRng(2);
      var diff = false;
      for (int i = 0; i < 50; i++) {
        if (a.nextInt(100000) != b.nextInt(100000)) diff = true;
      }
      expect(diff, isTrue);
    });
  });

  group('FuzzRecord', () {
    test('toMap / fromMap round-trip preserves values', () {
      final rng = FuzzRng(7);
      final rec = FuzzRecord.random(rng, allowNulls: false);
      final restored = FuzzRecord.fromMap(rec.toMap())!;
      expect(restored, rec);
    });

    test('equality normalizes DateTime UTC vs non-UTC', () {
      final rng = FuzzRng(11);
      final a = FuzzRecord.random(rng, allowNulls: false);
      // Same instant, constructed in local zone.
      final mapA = Map<String, dynamic>.from(a.toMap());
      mapA['dateTimeField'] = a.dateTimeField;
      final b = FuzzRecord.fromMap(mapA)!;
      expect(b, a);
    });

    test('equality detects a changed int field', () {
      final rng = FuzzRng(5);
      final a = FuzzRecord.random(rng, allowNulls: false);
      final bMap = Map<String, dynamic>.from(a.toMap());
      bMap['intField'] = (bMap['intField'] as int) + 1;
      final b = FuzzRecord.fromMap(bMap)!;
      expect(a == b, isFalse);
    });

    test('fromMap handles null optional fields', () {
      final map = <String, dynamic>{
        'boolField': true,
        'intField': 1,
        'doubleField': 2.5,
        'stringField': 's',
        'dateTimeField': null,
        'durationField': null,
        'uuidField': null,
        'bigIntField': null,
        'bytesField': null,
        'listField': <dynamic>[],
        'mapField': <String, dynamic>{},
        'relationField': null,
      };
      final rec = FuzzRecord.fromMap(map)!;
      expect(rec.dateTimeField, isNull);
      expect(rec.bytesField, isNull);
    });
  });
}
