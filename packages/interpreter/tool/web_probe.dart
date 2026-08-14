// Copyright (c) Ejenix authors. MIT license.

/// Proves the **runtime half** of the stack runs on the web.
///
/// The DoD requires a patch to apply on Web. `package:test`'s browser harness
/// cannot load suites from a pub workspace (the symlinked `packages/` directory
/// is served as `text/plain`, so the browser refuses the script) — that is a
/// test-runner limitation, not a code one. So prove the property directly:
///
///     dart compile js packages/interpreter/tool/web_probe.dart -o /tmp/probe.js
///     node /tmp/probe.js
///
/// It exercises what a device does on Web: interpret bytecode, verify an Ed25519
/// signature over a CBOR bundle, reject an untrusted key, and run the decoded
/// body. `dart:io` appears nowhere in `bytecode`, `interpreter`, or `bundle`,
/// which is what makes this possible.
library;

import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';

/// A module whose `main()` returns 6 * 7.
Module buildModule() {
  final constants = ConstantPool()
    ..add(6)
    ..add(7);
  final main =
      (BytecodeBuilder()
            ..emitABx(Op.loadConst, 0, 0)
            ..emitABx(Op.loadConst, 1, 1)
            ..emitABC(Op.mulInt, 2, 0, 1)
            ..emitA(Op.ret, 2))
          .toProto(name: 'main', paramCount: 0, registerCount: 3);
  return Module(constants: constants, functions: [main], entryFunction: 0);
}

void main() {
  var failures = 0;
  void check(String what, Object? actual, Object? expected) {
    final ok = actual == expected;
    if (!ok) failures++;
    print('${ok ? 'ok  ' : 'FAIL'}  $what -> $actual (expected $expected)');
  }

  // 1. The VM itself, under dart2js.
  check('interpret bytecode', Interpreter(buildModule()).run(), 42);

  // 2. Sign, encode, decode, verify — Ed25519 + SHA-256 + CBOR under dart2js.
  //    This is what a device does before it will run a patch at all.
  final signer = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 7));
  final bundle = Bundle.sign(
    module: buildModule(),
    metadata: const BundleMetadata(
      targetAppId: 'web.probe',
      targetFlutterVersion: '3.44.6',
      minSdk: '1.0.0',
    ),
    signer: signer,
    compilerVersion: '0.1.0',
    bundleId: Uint8List.fromList(List.generate(16, (i) => i)),
    createdAtMillis: 1720800000000,
  );

  final decoded = Bundle.decode(bundle.encode());
  check(
    'verify a signed bundle',
    decoded.verify(anchors: TrustAnchors.single(signer.publicKey)).isValid,
    true,
  );

  // 3. An untrusted key must be rejected on Web exactly as it is natively.
  //    Derived from a fixed seed, not `Signer.generate()`: generation needs a
  //    CSPRNG (`self.crypto`), which exists in a browser but not under Node —
  //    and a device never generates keys anyway. It only ever verifies.
  final attacker = Signer.fromSeed(Uint8List(32)..fillRange(0, 32, 9));
  check(
    'reject an untrusted key',
    decoded.verify(anchors: TrustAnchors.single(attacker.publicKey)).isValid,
    false,
  );

  // 4. The decoded body still runs.
  final (module, _) = decoded.decodeBody();
  check('run the decoded module', Interpreter(module).run(), 42);

  print(failures == 0 ? '\nWEB OK' : '\n$failures FAILURE(S)');
}
