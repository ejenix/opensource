// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// A small hand-built module returning `a + b`, with mixed-kind constants to
/// exercise type-preserving CBOR.
Module buildModule() {
  final constants = ConstantPool()
    ..add(42)
    ..add(3.14)
    ..add('hello')
    ..add(true)
    ..add(null);
  final add =
      (BytecodeBuilder()
            ..emitABC(Op.addInt, 2, 0, 1)
            ..emitA(Op.ret, 2))
          .toProto(name: 'add', paramCount: 2, registerCount: 3);
  return Module(constants: constants, functions: [add], entryFunction: 0);
}

const metadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  final seed = Uint8List(32)..fillRange(0, 32, 3);
  final signer = Signer.fromSeed(seed);
  final anchors = TrustAnchors.single(signer.publicKey);

  Bundle signFixture() => Bundle.sign(
    module: buildModule(),
    metadata: metadata,
    signer: signer,
    compilerVersion: '0.1.0',
    bundleId: Uint8List.fromList(List.generate(16, (i) => i)),
    createdAtMillis: 1720800000000,
  );

  group('ModuleCodec', () {
    test('round-trips a module and metadata, preserving constant types', () {
      final module = buildModule();
      final body = ModuleCodec.encodeBody(module, metadata);
      final (decoded, meta) = ModuleCodec.decodeBody(body);

      expect(meta, metadata);
      expect(decoded.entryFunction, module.entryFunction);
      expect(decoded.constants.values, [42, 3.14, 'hello', true, null]);
      expect(decoded.constants.values[0], isA<int>());
      expect(decoded.constants.values[1], isA<double>());
      expect(decoded.functions.single.name, 'add');
      expect(decoded.functions.single.code, module.functions.single.code);
    });
  });

  group('Bundle sign/encode/decode/verify', () {
    test('a freshly signed bundle verifies', () {
      final bundle = signFixture();
      expect(bundle.verify(anchors: anchors).isValid, isTrue);
    });

    test('encode/decode is a faithful round-trip', () {
      final bundle = signFixture();
      final decoded = Bundle.decode(bundle.encode());
      expect(decoded.bundleId, bundle.bundleId);
      expect(decoded.createdAtMillis, bundle.createdAtMillis);
      expect(decoded.compilerVersion, bundle.compilerVersion);
      expect(decoded.publicKey, bundle.publicKey);
      expect(decoded.signature, bundle.signature);
      expect(decoded.bodyBytes, bundle.bodyBytes);
      expect(decoded.verify(anchors: anchors).isValid, isTrue);
    });

    test('signing is deterministic for fixed id/time/version', () {
      expect(signFixture().encode(), signFixture().encode());
    });

    test('the signed wire format matches the checked-in golden', () {
      // Pins the exact bytes of a deterministic bundle so any accidental change
      // to the header, CBOR body layout, or signing input is caught. If the
      // format changed on purpose, regenerate test/bundle_format.golden and bump
      // the body version.
      // Resolve whether tests run from the package root or the workspace root.
      final goldenFile =
          [
                'test/bundle_format.golden',
                'packages/bundle/test/bundle_format.golden',
              ]
              .map(File.new)
              .firstWhere(
                (f) => f.existsSync(),
                orElse: () => throw StateError(
                  'golden not found from ${Directory.current.path}',
                ),
              );
      final golden = goldenFile.readAsStringSync().trim();
      final actual = [
        for (final b in signFixture().encode())
          b.toRadixString(16).padLeft(2, '0'),
      ].join();
      expect(
        actual,
        golden,
        reason: 'bundle wire format drifted from the golden fixture',
      );
    });

    test('a tampered body is rejected (hash mismatch)', () {
      final bundle = signFixture();
      final bytes = bundle.encode();
      // Flip the final byte, which lies within the body byte-string.
      bytes[bytes.length - 1] ^= 0xFF;
      final tampered = Bundle.decode(bytes);
      expect(
        tampered.verify(anchors: anchors).failure,
        BundleFailure.bodyHashMismatch,
      );
    });

    test('an untrusted key is rejected', () {
      final bundle = signFixture();
      final other = TrustAnchors.single(Signer.generate().publicKey);
      expect(bundle.verify(anchors: other).failure, BundleFailure.untrustedKey);
    });

    test('a tampered signature is rejected', () {
      final bundle = signFixture();
      final bytes = bundle.encode();
      final idx = _indexOf(bytes, bundle.signature);
      bytes[idx] ^= 0xFF;
      expect(
        Bundle.decode(bytes).verify(anchors: anchors).failure,
        BundleFailure.badSignature,
      );
    });

    test('bad magic is rejected', () {
      final bytes = signFixture().encode();
      final idx = _indexOf(bytes, bundleMagic);
      bytes[idx] = 0xFF;
      expect(
        Bundle.decode(bytes).verify(anchors: anchors).failure,
        BundleFailure.badMagic,
      );
    });

    test('incompatible major version is rejected', () {
      final bytes = signFixture().encode();
      final idx = _indexOf(bytes, bundleMagic);
      bytes[idx + 4] = 0x02; // version-major byte follows the 4 magic bytes
      expect(
        Bundle.decode(bytes).verify(anchors: anchors).failure,
        BundleFailure.incompatibleVersion,
      );
    });

    test('malformed bytes throw a format exception', () {
      expect(
        () => Bundle.decode(Uint8List.fromList([0x00, 0x01])),
        throwsA(isA<BundleFormatException>()),
      );
    });
  });

  group('formatting and metadata', () {
    test('verification results and exceptions render readably', () {
      expect(const BundleVerification.ok().toString(), contains('ok'));
      expect(
        const BundleVerification.failed(BundleFailure.badSignature).toString(),
        contains('badSignature'),
      );
      expect(BundleFormatException('x').toString(), contains('x'));
    });

    test('metadata equality and hashCode', () {
      expect(
        metadata,
        const BundleMetadata(
          targetAppId: 'com.example.app',
          targetFlutterVersion: '3.41.6',
          minSdk: '1.0.0',
        ),
      );
      expect(metadata.hashCode, isA<int>());
      expect(
        metadata ==
            const BundleMetadata(
              targetAppId: 'other',
              targetFlutterVersion: '3.41.6',
              minSdk: '1.0.0',
            ),
        isFalse,
      );
    });
  });

  group('end-to-end: compile -> sign -> verify -> run', () {
    test(
      'a compiled program survives the full pipeline and executes',
      () async {
        final result = await Compiler().compileSource('int main() => 6 * 7;');
        final module = result.moduleOrThrow;

        final bundle = Bundle.sign(
          module: module,
          metadata: metadata,
          signer: signer,
          compilerVersion: '0.1.0',
        );

        // Transit as bytes.
        final received = Bundle.decode(bundle.encode());
        expect(received.verify(anchors: anchors).isValid, isTrue);

        final (decodedModule, _) = received.decodeBody();
        expect(Interpreter(decodedModule).run(), 42);
      },
    );

    test('a program with dynamic dispatch round-trips its call sites', () async {
      // Uses method dispatch, so the module carries a call-site table (body v2).
      final result = await Compiler().compileSource(
        "String main() => 'hi'.toUpperCase();",
      );
      final module = result.moduleOrThrow;
      expect(module.callSites, isNotEmpty);

      final bundle = Bundle.sign(
        module: module,
        metadata: metadata,
        signer: signer,
        compilerVersion: '0.1.0',
      );
      final received = Bundle.decode(bundle.encode());
      final (decodedModule, _) = received.decodeBody();
      expect(decodedModule.callSites.length, module.callSites.length);
      expect(Interpreter(decodedModule).run(), 'HI');
    });

    test('a program with a user-defined class round-trips (body v3)', () async {
      // Exercises the class table: the module carries a ClassDescriptor that
      // must survive canonical CBOR encoding and drive dispatch after decode.
      final result = await Compiler().compileSource('''
class Point {
  int x, y;
  Point(this.x, this.y);
  int sum() => x + y;
}
int main() => Point(20, 22).sum();
''');
      final module = result.moduleOrThrow;
      expect(module.classes, isNotEmpty);

      final bundle = Bundle.sign(
        module: module,
        metadata: metadata,
        signer: signer,
        compilerVersion: '0.1.0',
      );
      final received = Bundle.decode(bundle.encode());
      expect(received.verify(anchors: anchors).isValid, isTrue);

      final (decodedModule, _) = received.decodeBody();
      expect(decodedModule.classes.length, module.classes.length);
      expect(decodedModule.classes.single.name, 'Point');
      expect(decodedModule.classes.single.fieldCount, 2);
      expect(decodedModule.classes.single.methods, contains('sum'));
      expect(Interpreter(decodedModule).run(), 42);
    });

    test('an enum program round-trips its EnumValue constants', () async {
      final result = await Compiler().compileSource(
        'enum Color { red, green, blue } int main() => Color.blue.index;',
      );
      final module = result.moduleOrThrow;
      expect(module.constants.values.whereType<EnumValue>(), isNotEmpty);

      final bundle = Bundle.sign(
        module: module,
        metadata: metadata,
        signer: signer,
        compilerVersion: '0.1.0',
      );
      final received = Bundle.decode(bundle.encode());
      expect(received.verify(anchors: anchors).isValid, isTrue);

      final (decodedModule, _) = received.decodeBody();
      expect(
        decodedModule.constants.values.whereType<EnumValue>().map(
          (e) => e.name,
        ),
        module.constants.values.whereType<EnumValue>().map((e) => e.name),
      );
      expect(Interpreter(decodedModule).run(), 2);
    });

    test('an async program round-trips its isAsync flag (body v5)', () async {
      final result = await Compiler().compileSource('''
Future<int> compute() async => 40 + 2;
Future<int> main() async => await compute();
''');
      final module = result.moduleOrThrow;
      expect(module.functions.any((f) => f.isAsync), isTrue);

      final bundle = Bundle.sign(
        module: module,
        metadata: metadata,
        signer: signer,
        compilerVersion: '0.1.0',
      );
      final received = Bundle.decode(bundle.encode());
      expect(received.verify(anchors: anchors).isValid, isTrue);

      final (decodedModule, _) = received.decodeBody();
      expect(
        decodedModule.functions.map((f) => f.isAsync),
        module.functions.map((f) => f.isAsync),
      );
      expect(await Interpreter(decodedModule).runAsync(), 42);
    });

    test(
      'a program with a closure round-trips its captures (body v4)',
      () async {
        // The nested closure captures `base`, so at least one function proto
        // carries a non-empty capture list that must survive encoding.
        final result = await Compiler().compileSource('''
int main() {
  var base = 40;
  int add(int x) => x + base;
  return add(2);
}
''');
        final module = result.moduleOrThrow;
        expect(module.functions.any((f) => f.captures.isNotEmpty), isTrue);

        final bundle = Bundle.sign(
          module: module,
          metadata: metadata,
          signer: signer,
          compilerVersion: '0.1.0',
        );
        final received = Bundle.decode(bundle.encode());
        expect(received.verify(anchors: anchors).isValid, isTrue);

        final (decodedModule, _) = received.decodeBody();
        final original = module.functions.map((f) => f.captures).toList();
        final restored = decodedModule.functions
            .map((f) => f.captures)
            .toList();
        expect(restored, original);
        expect(Interpreter(decodedModule).run(), 42);
      },
    );
  });
}

int _indexOf(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  throw StateError('needle not found');
}
