// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_interpreter/interpreter.dart';

/// Simulates the on-device apply step: verify a signed bundle against a trusted
/// public key, then execute its entry point through the sandboxed interpreter.
/// This is exactly what the device loader does before activating a patch, minus
/// the fetch/stage/rollback lifecycle (see `packages/loader`).
///
/// Usage: `dart run bin/apply.dart <bundle> <pubkey.pub>`
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: apply <bundle> <pubkey.pub>');
    exit(64);
  }

  final bytes = File(args[0]).readAsBytesSync();
  final anchors = TrustAnchors.single(_unhex(File(args[1]).readAsStringSync()));

  final Bundle bundle;
  try {
    bundle = Bundle.decode(bytes);
  } on BundleFormatException catch (e) {
    stderr.writeln('REJECTED: malformed bundle: ${e.message}');
    exit(1);
  }

  final result = bundle.verify(anchors: anchors);
  if (!result.isValid) {
    stderr.writeln('REJECTED: ${result.failure}');
    exit(1);
  }
  stdout.writeln('✓ signature and content integrity verified');

  final (module, metadata) = bundle.decodeBody();
  stdout.writeln('  target app: ${metadata.targetAppId}');

  // The interpreter is sandboxed: bytecode reaches the host only through the
  // registered host-API allow-list. No reflection, no dart:io.
  final value = Interpreter(module).run();
  stdout.writeln('✓ applied patch → main() = $value');
}

Uint8List _unhex(String hex) {
  final h = hex.trim();
  return Uint8List.fromList([
    for (var i = 0; i + 1 < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
}
