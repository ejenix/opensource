// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_delta/delta.dart';
import 'package:test/test.dart';

Module moduleReturning(int value) {
  final fn =
      (BytecodeBuilder()
            ..emitLoadInt(0, value)
            ..emitA(Op.ret, 0))
          .toProto(name: 'main', paramCount: 0, registerCount: 1);
  return Module(constants: ConstantPool(), functions: [fn], entryFunction: 0);
}

const metadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 5));
  final anchors = TrustAnchors.single(signer.publicKey);

  Bundle sign(int value, {required int id}) => Bundle.sign(
    module: moduleReturning(value),
    metadata: metadata,
    signer: signer,
    compilerVersion: '0.1.0',
    bundleId: Uint8List(16)..fillRange(0, 16, id),
  );

  test('a signed delta bundle verifies and reconstructs the target bundle', () {
    final base = sign(1, id: 1);
    final target = sign(2, id: 2);

    final deltaBundle = DeltaBundle.create(
      base: base,
      target: target,
      signer: signer,
      compilerVersion: '0.1.0',
    );

    // The delta bundle is itself a normal, verifiable bundle.
    expect(deltaBundle.verify(anchors: anchors).isValid, isTrue);
    expect(DeltaBundle.isDelta(deltaBundle), isTrue);
    expect(DeltaBundle.isDelta(base), isFalse);
    expect(DeltaBundle.baseBundleIdOf(deltaBundle), base.bundleId);

    // Applying against the cached base reproduces the full target bundle, which
    // verifies end-to-end on its own signature.
    final reconstructed = DeltaBundle.apply(deltaBundle, base.encode());
    expect(reconstructed, target.encode());
    final rebuilt = Bundle.decode(reconstructed);
    expect(rebuilt.verify(anchors: anchors).isValid, isTrue);
    expect(rebuilt.decodeBody().$1.functions.single.name, 'main');
  });

  test('applying against the wrong base fails the post-patch hash', () {
    final base = sign(1, id: 1);
    final target = sign(2, id: 2);
    final wrongBase = sign(999, id: 9);
    final deltaBundle = DeltaBundle.create(
      base: base,
      target: target,
      signer: signer,
      compilerVersion: '0.1.0',
    );
    expect(
      () => DeltaBundle.apply(deltaBundle, wrongBase.encode()),
      throwsA(isA<DeltaException>()),
    );
  });

  test('DeltaBody encodes and decodes', () {
    final body = DeltaBody(
      baseBundleId: Uint8List.fromList(List.generate(16, (i) => i)),
      patch: Uint8List.fromList([1, 2, 3, 4]),
      postPatchSha256: Uint8List(32)..fillRange(0, 32, 7),
    );
    final decoded = DeltaBody.decode(body.encode());
    expect(decoded.baseBundleId, body.baseBundleId);
    expect(decoded.patch, body.patch);
    expect(decoded.postPatchSha256, body.postPatchSha256);
  });

  test('DeltaBody.decode rejects a malformed body', () {
    final bad =
        (CborWriter()
              ..writeArrayHeader(1)
              ..writeInt(0))
            .takeBytes();
    expect(() => DeltaBody.decode(bad), throwsA(isA<DeltaException>()));
  });
}
