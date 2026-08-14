// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:test/test.dart';

void main() {
  group('CBOR reader edge cases', () {
    test('CborException renders its message', () {
      expect(CborException('boom').toString(), contains('boom'));
    });

    test('readValue rejects an unexpected simple value', () {
      // 0xF7 is "undefined" (major 7, ai 23) — not one we accept.
      expect(
        () => CborReader(Uint8List.fromList([0xF7])).readValue(),
        throwsA(isA<CborException>()),
      );
    });

    test('readValue rejects an unexpected major type', () {
      // 0x40 is an empty byte string (major 2) — not a constant kind.
      expect(
        () => CborReader(Uint8List.fromList([0x40])).readValue(),
        throwsA(isA<CborException>()),
      );
    });

    test('readDouble rejects a non-float head', () {
      expect(
        () => CborReader(Uint8List.fromList([0x00])).readDouble(),
        throwsA(isA<CborException>()),
      );
    });

    test('reserved additional info is rejected', () {
      // 0x1F is major 0 with additional info 31 (reserved).
      expect(
        () => CborReader(Uint8List.fromList([0x1F])).readInt(),
        throwsA(isA<CborException>()),
      );
    });

    test('truncated byte string is rejected', () {
      // Says 4 bytes follow, but provides none.
      expect(
        () => CborReader(Uint8List.fromList([0x44])).readBytes(),
        throwsA(isA<CborException>()),
      );
    });
  });

  group('ModuleCodec errors', () {
    test('rejects a body that is not a 5-element array', () {
      final bad =
          (CborWriter()
                ..writeArrayHeader(2)
                ..writeInt(1)
                ..writeInt(2))
              .takeBytes();
      expect(() => ModuleCodec.decodeBody(bad), throwsA(isA<CborException>()));
    });

    test('rejects an unsupported body version', () {
      final w = CborWriter()
        ..writeArrayHeader(5)
        ..writeInt(999) // version
        ..writeArrayHeader(0)
        ..writeArrayHeader(0)
        ..writeInt(-1)
        ..writeArrayHeader(3)
        ..writeString('a')
        ..writeString('b')
        ..writeString('c');
      expect(
        () => ModuleCodec.decodeBody(w.takeBytes()),
        throwsA(isA<CborException>()),
      );
    });

    test('rejects bytecode whose length is not a multiple of 4', () {
      // Hand-build a body whose single function has a 3-byte code blob.
      final w = CborWriter()
        ..writeArrayHeader(5)
        ..writeInt(ModuleCodec.bodyFormatVersion)
        ..writeArrayHeader(0)
        ..writeArrayHeader(1)
        ..writeArrayHeader(4)
        ..writeString('f')
        ..writeInt(0)
        ..writeInt(1)
        ..writeBytes(Uint8List(3)) // not a multiple of 4
        ..writeInt(-1)
        ..writeArrayHeader(3)
        ..writeString('a')
        ..writeString('b')
        ..writeString('c');
      expect(
        () => ModuleCodec.decodeBody(w.takeBytes()),
        throwsA(isA<CborException>()),
      );
    });
  });

  group('small guards', () {
    test('formatUuid rejects the wrong length', () {
      expect(() => formatUuid(Uint8List(4)), throwsArgumentError);
    });

    test('signer exposes its seed', () {
      final seed = Uint8List(32)..fillRange(0, 32, 9);
      expect(Signer.fromSeed(seed).seed, seed);
    });
  });
}
