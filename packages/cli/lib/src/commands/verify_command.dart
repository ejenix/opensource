// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_interpreter/interpreter.dart';

import '../base_command.dart';
import '../util.dart';

/// `ejenix verify <bundle> --key <pubkey>` — offline verification.
class VerifyCommand extends EjenixCommand {
  VerifyCommand() {
    argParser
      ..addOption(
        'key',
        help: 'Trusted public key: a .pub file path or inline hex.',
      )
      ..addOption(
        'capabilities',
        help:
            'A capability manifest (JSON list, or {"globals": [...]}) listing '
            'what the target app registers. Fails if the patch needs anything '
            'absent from it — run this in CI, before publishing.',
      );
  }

  @override
  String get name => 'verify';

  @override
  String get description => 'Verify a bundle offline against a trusted key.';

  @override
  String get invocation =>
      'ejenix verify <bundle> --key <pubkey> [--capabilities <manifest.json>]';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliException('missing bundle file', exitCode: 64);
    final keyArg =
        argResults!['key'] as String? ??
        (throw CliException('missing required --key', exitCode: 64));

    final anchor = readPublicKeyArg(keyArg);
    final bundle = loadBundle(rest.first);
    final result = bundle.verify(anchors: TrustAnchors.single(anchor));

    if (result.isValid) {
      // Signature says the bytes are authentic. It says nothing about whether
      // the app can run them: a patch calling a capability released after the
      // build in the store is perfectly signed and still dead on arrival. That
      // is the failure this flag exists to catch, in CI rather than on a phone.
      final manifestPath = argResults!['capabilities'] as String?;
      if (manifestPath != null) {
        final shipped = _readManifest(manifestPath);
        final (module, _) = bundle.decodeBody();
        final missing = [
          for (final need in requiredHostGlobals(module))
            if (!shipped.contains(need)) need,
        ];
        if (missing.isNotEmpty) {
          console.error(
            'patch needs ${missing.length} capability(ies) the app does not '
            'register: ${missing.join(', ')}',
          );
          console.error(
            'Ship a build registering them first — a patch cannot add one. '
            'Regenerate the manifest after releasing that build.',
          );
          console.emitJson({
            'valid': true,
            'runnable': false,
            'missingCapabilities': missing,
          });
          return 65; // EX_DATAERR
        }
        console.success('bundle is valid and runnable against the manifest');
        console.emitJson({
          'valid': true,
          'runnable': true,
          'bundleId': formatUuid(bundle.bundleId),
        });
        return 0;
      }

      console.success('bundle is valid');
      console.emitJson({
        'valid': true,
        'bundleId': formatUuid(bundle.bundleId),
      });
      return 0;
    }
    console.error('verification failed: ${result.failure!.name}');
    console.emitJson({'valid': false, 'failure': result.failure!.name});
    return 1;
  }
}

/// Reads a capability manifest: either a bare JSON list of names, or an object
/// with a `globals` key (what `ejenix gen --out-manifest` writes).
Set<String> _readManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw CliException('capability manifest not found: $path', exitCode: 66);
  }
  final Object? json;
  try {
    json = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    throw CliException(
      'manifest is not valid JSON: ${e.message}',
      exitCode: 65,
    );
  }
  final list = switch (json) {
    List<Object?> l => l,
    Map<String, Object?> m when m['globals'] is List => m['globals']! as List,
    _ => throw CliException(
      'manifest must be a JSON list of capability names, or an object with a '
      '"globals" list',
      exitCode: 65,
    ),
  };
  return {for (final e in list) '$e'};
}
