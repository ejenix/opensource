// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';

import '../base_command.dart';
import '../util.dart';

/// `ejenix keygen --out <path>` — generate a fresh Ed25519 keypair.
class KeygenCommand extends EjenixCommand {
  KeygenCommand() {
    argParser
      ..addOption('out', abbr: 'o', help: 'Path to write the private seed.')
      ..addFlag(
        'force',
        help: 'Overwrite existing key files.',
        negatable: false,
      );
  }

  @override
  String get name => 'keygen';

  @override
  String get description => 'Generate a new Ed25519 signing keypair.';

  @override
  String get invocation => 'ejenix keygen --out <path>';

  @override
  Future<int> execute() async {
    final out = argResults!['out'] as String?;
    if (out == null) throw CliException('missing required --out', exitCode: 64);
    final force = argResults!['force'] as bool;

    final seedFile = File(out);
    final pubFile = File('$out.pub');
    if (!force && (seedFile.existsSync() || pubFile.existsSync())) {
      throw CliException('key files already exist; pass --force to overwrite');
    }

    final signer = Signer.generate();
    await _writePrivateSeed(seedFile, toHex(signer.seed));
    pubFile.writeAsStringSync(toHex(signer.publicKey));

    console.success('wrote private seed to $out');
    console.info('public key ($out.pub): ${toHex(signer.publicKey)}');
    console.emitJson({
      'privateKey': out,
      'publicKey': '$out.pub',
      'publicKeyHex': toHex(signer.publicKey),
    });
    return 0;
  }
}

/// Writes a signing seed so that it is never readable by anyone but its owner,
/// not even for the instant between creation and the write.
///
/// This is the one file in the toolchain whose disclosure is unrecoverable: the
/// seed is the authority every device was built to trust, and it cannot be
/// revoked without shipping a new binary. `writeAsString` alone applies the
/// ambient umask, which on a typical machine leaves it world-readable — on a
/// shared CI runner or a developer box with a broad umask, that is the whole
/// trust model sitting in a file anyone can `cat`.
///
/// The order matters:
///
/// 1. create an empty temp file beside the target;
/// 2. restrict it to owner-only *before* any secret exists in it;
/// 3. write the seed;
/// 4. rename over the target, which is atomic within a filesystem and carries
///    the restricted mode with it.
///
/// Writing the seed first and restricting afterwards would leave a window,
/// however brief, where the key is on disk and readable.
Future<void> _writePrivateSeed(File target, String seedHex) async {
  final tmp = File('${target.path}.tmp');
  try {
    tmp.writeAsStringSync('');
    await _restrictToOwner(tmp);
    tmp.writeAsStringSync(seedHex, flush: true);
    tmp.renameSync(target.path);
  } catch (_) {
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } on FileSystemException {
        // Best effort: the throw below is the useful signal, not this.
      }
    }
    rethrow;
  }
}

/// Restricts [file] to `0600`, then verifies it took.
///
/// Dart exposes no `chmod`, so this shells out on POSIX. The verification is
/// not paranoia about `chmod` itself — it also catches filesystems that ignore
/// permission bits (a mounted share, some container volumes), where the write
/// would otherwise appear to succeed while leaving the key exposed.
Future<void> _restrictToOwner(File file) async {
  if (Platform.isWindows) {
    // No POSIX mode on NTFS; the file inherits the directory's ACL, and there
    // is no portable equivalent worth shelling out for. Documented rather than
    // silently pretended.
    return;
  }

  final result = await Process.run('chmod', ['600', file.path]);
  if (result.exitCode != 0) {
    throw CliException(
      'could not restrict permissions on ${file.path}: ${result.stderr}',
      exitCode: 73, // EX_CANTCREAT
    );
  }

  // 0o077 is every group and other bit. Anything set means the seed would be
  // readable beyond its owner, so refuse rather than write a key we have just
  // failed to protect.
  final mode = file.statSync().mode;
  if (mode & 0x3F != 0) {
    throw CliException(
      'refusing to write a signing key that is not owner-only: '
      '${file.path} is ${file.statSync().modeString()}. '
      'The filesystem may not support permission bits.',
      exitCode: 73,
    );
  }
}
