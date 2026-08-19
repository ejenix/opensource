// Copyright (c) Ejenix authors. MIT license.

/// `Bundle.decode` is the first thing a hostile server's bytes reach — it runs
/// *before* any signature is checked. Signature verification protects what
/// executes; it does nothing for what the decoder does on the way there.
///
/// So the decoder must be total (no untyped exception escapes), bounded (no
/// length prefix drives an allocation), and exact (one complete document, in
/// canonical form, or nothing).
library;

import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

Module _mod() {
  final f =
      (BytecodeBuilder()
            ..emitLoadInt(0, 7)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [f], entryFunction: 0);
}

Uint8List _validBundle() => Bundle.sign(
  module: _mod(),
  metadata: const BundleMetadata(
    targetAppId: 'com.example.app',
    targetFlutterVersion: '3.41.6',
    minSdk: '1.0.0',
  ),
  signer: Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 3)),
  compilerVersion: '0.1.0',
).encode();

void main() {
  test('a well-formed bundle still decodes', () {
    // The guard against over-correcting: strictness that rejects real bundles
    // would be a far worse outage than the inputs it turns away.
    expect(() => Bundle.decode(_validBundle()), returnsNormally);
  });

  test('trailing bytes are refused', () {
    // They sit outside everything the signature covers, so accepting them
    // means two different byte strings are the "same" bundle.
    final b = _validBundle();
    final padded = Uint8List(b.length + 4)..setAll(0, b);
    expect(() => Bundle.decode(padded), throwsA(isA<BundleFormatException>()));
  });

  test('truncation at every offset is a format error, never a crash', () {
    // The property that matters most: whatever a hostile server sends, the
    // failure is typed. A RangeError or FormatException escaping here would
    // bypass every caller's error handling.
    final b = _validBundle();
    for (var cut = 1; cut < b.length; cut++) {
      final short = Uint8List.sublistView(b, 0, cut);
      expect(
        () => Bundle.decode(short),
        throwsA(isA<BundleFormatException>()),
        reason: 'truncating to $cut bytes escaped as an untyped error',
      );
    }
  });

  test('random corruption never escapes as an untyped error', () {
    final b = _validBundle();
    for (var seed = 0; seed < 400; seed++) {
      final mutated = Uint8List.fromList(b);
      mutated[seed % mutated.length] ^= (seed % 251) + 1;
      try {
        Bundle.decode(mutated);
      } on BundleFormatException {
        // Expected.
      } catch (e) {
        fail('seed $seed escaped as ${e.runtimeType}: $e');
      }
    }
  });

  test('a huge declared length is refused before it allocates', () {
    // 0x5A = byte string with a 4-byte length. Claim ~4GB in an 8-byte input:
    // an unbounded reader would try to honour it.
    final bomb = Uint8List.fromList([
      0x84,
      0x5A,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0x00,
      0x00,
    ]);
    expect(() => Bundle.decode(bomb), throwsA(isA<BundleFormatException>()));
  });

  test('a non-canonical integer encoding is refused', () {
    // 0x18 0x05 encodes 5 in two bytes when one would do. Two byte strings
    // decoding to one value breaks the guarantee a body hash is meant to give.
    final nonCanonical = Uint8List.fromList([0x84, 0x18, 0x05]);
    expect(
      () => Bundle.decode(nonCanonical),
      throwsA(isA<BundleFormatException>()),
    );
  });

  group('fixed-width fields', () {
    test('a wrong-size key or signature is a format error', () {
      // Caught as malformed input rather than surfacing later as a confusing
      // verification failure.
      final b = _validBundle();
      // Flip the length nibble of a known short field by corrupting the
      // header region; any resulting size mismatch must be typed.
      for (var i = 1; i < 40 && i < b.length; i++) {
        final m = Uint8List.fromList(b);
        m[i] = 0x40; // empty byte string header
        try {
          Bundle.decode(m);
        } on BundleFormatException {
          // Expected.
        } catch (e) {
          fail('offset $i escaped as ${e.runtimeType}');
        }
      }
    });
  });
}
