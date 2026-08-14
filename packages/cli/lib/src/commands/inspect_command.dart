// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';

import 'package:ejenix_interpreter/interpreter.dart';

import '../base_command.dart';
import '../util.dart';

/// `ejenix inspect <bundle>` — human-readable metadata and disassembly.
class InspectCommand extends EjenixCommand {
  @override
  String get name => 'inspect';

  @override
  String get description => 'Print a bundle\'s metadata and disassembly.';

  @override
  String get invocation => 'ejenix inspect <bundle>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) throw CliException('missing bundle file', exitCode: 64);
    final bundle = loadBundle(rest.first);

    final (module, metadata) = _decodeBody(bundle);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      bundle.createdAtMillis,
    ).toUtc().toIso8601String();

    console.info('bundle-id:        ${formatUuid(bundle.bundleId)}');
    console.info('created-at:       $createdAt');
    console.info('compiler-version: ${bundle.compilerVersion}');
    console.info('public-key:       ${toHex(bundle.publicKey)}');
    console.info('target-app:       ${metadata.targetAppId}');
    console.info('flutter-version:  ${metadata.targetFlutterVersion}');
    console.info('min-sdk:          ${metadata.minSdk}');
    console.info('functions:        ${module.functions.length}');
    final needs = requiredHostGlobals(module);
    console.info('needs-capabilities: ${needs.length}');
    for (final n in needs) {
      console.info('  - $n');
    }
    console.info('');
    console.info(Disassembler.disassemble(module));

    console.emitJson({
      'bundleId': formatUuid(bundle.bundleId),
      'createdAt': createdAt,
      'compilerVersion': bundle.compilerVersion,
      'publicKey': toHex(bundle.publicKey),
      'metadata': {
        'targetAppId': metadata.targetAppId,
        'targetFlutterVersion': metadata.targetFlutterVersion,
        'minSdk': metadata.minSdk,
      },
      // What the app must already register for this patch to run. The list a
      // release engineer diffs against their build before promoting.
      'requiredCapabilities': needs,
      'functions': [
        for (final fn in module.functions)
          {
            'name': fn.name,
            'params': fn.paramCount,
            'registers': fn.registerCount,
            'instructions': fn.code.length,
          },
      ],
    });
    return 0;
  }

  (Module, BundleMetadata) _decodeBody(Bundle bundle) {
    try {
      return bundle.decodeBody();
    } on CborException catch (e) {
      throw CliException('unreadable bundle body: ${e.message}', exitCode: 65);
    }
  }
}
