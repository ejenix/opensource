// Copyright (c) Ejenix authors. MIT license.

import 'dart:math';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:test/test.dart';

void main() {
  group('Signer', () {
    test('sign/verify round-trip', () {
      final signer = Signer.generate();
      final message = Uint8List.fromList([1, 2, 3, 4]);
      final sig = signer.sign(message);
      expect(sig.length, 64);
      expect(verifySignature(signer.publicKey, message, sig), isTrue);
    });

    test('deterministic from seed', () {
      final seed = Uint8List(32)..fillRange(0, 32, 7);
      final a = Signer.fromSeed(seed);
      final b = Signer.fromSeed(seed);
      expect(a.publicKey, b.publicKey);
      final message = Uint8List.fromList([9, 9]);
      expect(a.sign(message), b.sign(message));
    });

    test('rejects a tampered message', () {
      final signer = Signer.generate();
      final sig = signer.sign(Uint8List.fromList([1, 2, 3]));
      expect(
        verifySignature(signer.publicKey, Uint8List.fromList([1, 2, 4]), sig),
        isFalse,
      );
    });

    test('rejects the wrong public key', () {
      final signer = Signer.generate();
      final other = Signer.generate();
      final message = Uint8List.fromList([5]);
      final sig = signer.sign(message);
      expect(verifySignature(other.publicKey, message, sig), isFalse);
    });

    test('verifySignature returns false (not throws) on malformed input', () {
      expect(
        verifySignature(Uint8List(10), Uint8List(1), Uint8List(64)),
        isFalse,
      );
      expect(
        verifySignature(Uint8List(32), Uint8List(1), Uint8List(10)),
        isFalse,
      );
    });
  });

  group('UUIDv7', () {
    test('sets the version and variant bits', () {
      final id = uuidV7(millis: 0x0123456789AB, random: Random(1));
      expect(id.length, 16);
      expect(id[6] & 0xF0, 0x70); // version 7
      expect(id[8] & 0xC0, 0x80); // variant 10
    });

    test('encodes the timestamp big-endian in the first six bytes', () {
      const ms = 0x0123456789AB;
      final id = uuidV7(millis: ms, random: Random(1));
      expect(id.sublist(0, 6), [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB]);
    });

    test('later timestamps sort after earlier ones', () {
      final a = uuidV7(millis: 1000, random: Random(1));
      final b = uuidV7(millis: 2000, random: Random(1));
      expect(_lexCompare(a, b) < 0, isTrue);
    });

    test('formatUuid renders canonical 8-4-4-4-12', () {
      final id = Uint8List.fromList(List.generate(16, (i) => i));
      expect(formatUuid(id), '00010203-0405-0607-0809-0a0b0c0d0e0f');
    });
  });
}

int _lexCompare(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}
