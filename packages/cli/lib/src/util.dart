// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:path/path.dart' as p;

import 'base_command.dart';

/// Converts a filesystem path into the form a Dart `import` takes.
///
/// Import URIs are always POSIX-style, on every platform. A relative path from
/// `p.relative` uses the *platform* separator, so on Windows it comes back as
/// `..\patch_sdk` — and interpolating that into `import '...'` emits a
/// backslash, which is a string escape in Dart, not a path separator. Splitting
/// on the platform separator and rejoining with `/` is the whole fix.
///
/// On POSIX this is the identity function; it exists so generated code is
/// identical no matter which machine generated it. [context] defaults to the
/// host's, and is injectable so the Windows behaviour is testable from any
/// platform rather than only on a Windows CI runner.
String toImportPath(String path, {p.Context? context}) =>
    (context ?? p.context).split(path).join('/');

/// Encodes [bytes] as lowercase hex.
String toHex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Decodes a hex string to bytes. Throws [FormatException] on odd length or a
/// non-hex character.
Uint8List fromHex(String hex) {
  final trimmed = hex.trim();
  if (trimmed.length.isOdd) {
    throw const FormatException('hex string has an odd length');
  }
  return Uint8List.fromList([
    for (var i = 0; i < trimmed.length; i += 2)
      int.parse(trimmed.substring(i, i + 2), radix: 16),
  ]);
}

/// Reads a 32-byte Ed25519 seed from the hex file at [path].
Uint8List readSeedFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw CliException('signing key not found: $path', exitCode: 66);
  }
  final Uint8List seed;
  try {
    seed = fromHex(file.readAsStringSync());
  } on FormatException {
    throw CliException('signing key is not valid hex: $path', exitCode: 65);
  }
  if (seed.length != 32) {
    throw CliException(
      'signing key must be 32 bytes, got ${seed.length}',
      exitCode: 65,
    );
  }
  return seed;
}

/// Reads a 32-byte public key from [value], which may be a path to a `.pub`
/// file or an inline hex string.
Uint8List readPublicKeyArg(String value) {
  final file = File(value);
  final source = file.existsSync() ? file.readAsStringSync() : value;
  final Uint8List key;
  try {
    key = fromHex(source);
  } on FormatException {
    throw CliException('public key is not valid hex: $value', exitCode: 65);
  }
  if (key.length != 32) {
    throw CliException(
      'public key must be 32 bytes, got ${key.length}',
      exitCode: 65,
    );
  }
  return key;
}

/// Loads and decodes a bundle from [path].
Bundle loadBundle(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw CliException('bundle not found: $path', exitCode: 66);
  }
  try {
    return Bundle.decode(file.readAsBytesSync());
  } on BundleFormatException catch (e) {
    throw CliException('malformed bundle: ${e.message}', exitCode: 65);
  }
}
