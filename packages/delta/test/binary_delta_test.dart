// Copyright (c) Ejenix authors. MIT license.

import 'dart:math';
import 'dart:typed_data';

import 'package:ejenix_delta/delta.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> xs) => Uint8List.fromList(xs);

void main() {
  group('BinaryDelta round-trips', () {
    test('identical buffers', () {
      final base = _bytes(List.generate(1000, (i) => i % 256));
      final patch = BinaryDelta.computeDelta(base, base);
      expect(BinaryDelta.applyDelta(base, patch), base);
    });

    test('empty target and empty base', () {
      expect(
        BinaryDelta.applyDelta(
          _bytes([1, 2, 3]),
          BinaryDelta.computeDelta(_bytes([1, 2, 3]), _bytes([])),
        ),
        isEmpty,
      );
      final p = BinaryDelta.computeDelta(_bytes([]), _bytes([9, 8, 7]));
      expect(BinaryDelta.applyDelta(_bytes([]), p), _bytes([9, 8, 7]));
    });

    test('a localized edit in the middle', () {
      final base = _bytes(List.generate(4096, (i) => (i * 7) % 256));
      final target = Uint8List.fromList(base);
      for (var i = 2000; i < 2010; i++) {
        target[i] = 0xAB;
      }
      final patch = BinaryDelta.computeDelta(base, target);
      expect(BinaryDelta.applyDelta(base, patch), target);
    });

    test('insertion and deletion', () {
      final base = _bytes(List.generate(2000, (i) => (i * 3) % 251));
      final target = <int>[
        ...base.sublist(0, 500),
        1, 2, 3, 4, 5, // inserted
        ...base.sublist(700), // 200 bytes deleted
      ];
      final patch = BinaryDelta.computeDelta(base, Uint8List.fromList(target));
      expect(BinaryDelta.applyDelta(base, patch), target);
    });

    test('random fuzzing never corrupts the round-trip', () {
      final rng = Random(20260712);
      for (var trial = 0; trial < 40; trial++) {
        final base = Uint8List.fromList(
          List.generate(rng.nextInt(500), (_) => rng.nextInt(256)),
        );
        // Derive target by random edits of base.
        final target = base.toList();
        final edits = rng.nextInt(20);
        for (var e = 0; e < edits && target.isNotEmpty; e++) {
          target[rng.nextInt(target.length)] = rng.nextInt(256);
        }
        if (rng.nextBool())
          target.addAll([
            for (var i = 0; i < rng.nextInt(50); i++) rng.nextInt(256),
          ]);
        final t = Uint8List.fromList(target);
        final patch = BinaryDelta.computeDelta(base, t);
        expect(BinaryDelta.applyDelta(base, patch), t, reason: 'trial $trial');
      }
    });
  });

  group('compression ratio', () {
    test('a small edit produces a patch far smaller than the base', () {
      final base = _bytes(List.generate(100000, (i) => (i * 131 + 7) % 256));
      final target = Uint8List.fromList(base);
      // Change 100 bytes out of 100k.
      for (var i = 50000; i < 50100; i++) {
        target[i] = 0x00;
      }
      final patch = BinaryDelta.computeDelta(base, target);
      // Comfortably under the 10% target of brief §6.5.
      expect(patch.length, lessThan(base.length ~/ 10));
    });
  });

  group('corruption handling', () {
    test('non-zlib patch is rejected', () {
      expect(
        () => BinaryDelta.applyDelta(_bytes([1, 2, 3]), _bytes([0, 1, 2, 3])),
        throwsA(isA<DeltaException>()),
      );
    });

    test('a COPY beyond the base is rejected', () {
      // Build a valid patch then apply it against a too-short base.
      final base = _bytes(List.generate(64, (i) => i));
      final target = Uint8List.fromList(base);
      final patch = BinaryDelta.computeDelta(base, target);
      expect(
        () => BinaryDelta.applyDelta(_bytes([1, 2]), patch),
        throwsA(isA<DeltaException>()),
      );
    });
  });
}
