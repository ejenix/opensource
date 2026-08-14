// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bundle/src/cbor.dart';
import 'package:test/test.dart';

void main() {
  group('CBOR round-trips', () {
    test('integers across the size boundaries', () {
      for (final value in [
        0,
        1,
        23,
        24,
        255,
        256,
        65535,
        65536,
        0xFFFFFFFF,
        0x100000000,
        -1,
        -24,
        -256,
        -65536,
        9007199254740991,
      ]) {
        final bytes = (CborWriter()..writeInt(value)).takeBytes();
        expect(CborReader(bytes).readInt(), value, reason: '$value');
      }
    });

    test('shortest-form encoding is used', () {
      expect((CborWriter()..writeInt(10)).takeBytes(), [0x0A]);
      expect((CborWriter()..writeInt(200)).takeBytes(), [0x18, 0xC8]);
      expect((CborWriter()..writeInt(1000)).takeBytes(), [0x19, 0x03, 0xE8]);
      expect((CborWriter()..writeInt(-1)).takeBytes(), [0x20]);
    });

    test('strings, bytes, bools, null, doubles', () {
      expect(
        CborReader(
          (CborWriter()..writeString('héllo')).takeBytes(),
        ).readString(),
        'héllo',
      );
      final bytes = Uint8List.fromList([1, 2, 3, 255]);
      expect(
        CborReader((CborWriter()..writeBytes(bytes)).takeBytes()).readBytes(),
        bytes,
      );
      expect(
        CborReader((CborWriter()..writeBool(true)).takeBytes()).readValue(),
        isTrue,
      );
      expect(
        CborReader((CborWriter()..writeNull()).takeBytes()).readValue(),
        isNull,
      );
      expect(
        CborReader(
          (CborWriter()..writeDouble(3.14159)).takeBytes(),
        ).readDouble(),
        3.14159,
      );
    });

    test('writeValue/readValue preserve type', () {
      for (final value in <Object?>[null, true, false, 42, -7, 3.5, 'x']) {
        final bytes = (CborWriter()..writeValue(value)).takeBytes();
        final decoded = CborReader(bytes).readValue();
        expect(decoded, value);
        expect(decoded.runtimeType, value.runtimeType);
      }
    });

    test('arrays', () {
      final w = CborWriter()..writeArrayHeader(3);
      w
        ..writeInt(1)
        ..writeString('two')
        ..writeBool(false);
      final r = CborReader(w.takeBytes());
      expect(r.readArrayHeader(), 3);
      expect(r.readInt(), 1);
      expect(r.readString(), 'two');
      expect(r.readValue(), isFalse);
    });
  });

  group('CBOR determinism', () {
    test('identical values encode to identical bytes', () {
      Uint8List enc() =>
          (CborWriter()
                ..writeArrayHeader(2)
                ..writeString('k')
                ..writeInt(123456))
              .takeBytes();
      expect(enc(), enc());
    });
  });

  group('CBOR errors', () {
    test('truncated input throws', () {
      expect(
        () => CborReader(Uint8List.fromList([0x19, 0x03])).readInt(),
        throwsA(isA<CborException>()),
      );
    });

    test('type mismatch throws', () {
      final bytes = (CborWriter()..writeString('x')).takeBytes();
      expect(() => CborReader(bytes).readInt(), throwsA(isA<CborException>()));
    });

    test('unsupported value kind throws on write', () {
      expect(
        () => CborWriter()..writeValue(DateTime(2026)),
        throwsA(isA<CborException>()),
      );
    });
  });
}
