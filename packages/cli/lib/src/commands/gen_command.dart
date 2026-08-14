// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;

import '../base_command.dart';
import '../codegen/capability_gen.dart';
import '../util.dart';

/// `ejenix gen <file...> --out-sdk <path> --out-capabilities <path>` —
/// reads `@Patchable` annotations off your real app code and writes both the
/// patch SDK and the host registrations, so a capability's signature is written
/// once instead of three times.
class GenCommand extends EjenixCommand {
  GenCommand() {
    argParser
      ..addOption(
        'out-sdk',
        help:
            'Where to write the generated patch SDK (e.g. patch_sdk/app.dart).',
      )
      ..addOption(
        'out-capabilities',
        help:
            'Where to write the generated HostExtension (e.g. '
            'lib/app_capabilities.g.dart).',
      )
      ..addOption(
        'sdk-import',
        help: "The framework library the generated SDK imports beside it.",
        defaultsTo: 'flutter.dart',
      );
  }

  @override
  String get name => 'gen';

  @override
  String get description =>
      'Generate the patch SDK and host capabilities from @Patchable code.';

  @override
  String get invocation =>
      'ejenix gen <file.dart...> --out-sdk <path> --out-capabilities <path>';

  @override
  Future<int> execute() async {
    final inputs = argResults!.rest;
    if (inputs.isEmpty) {
      throw CliException('missing input .dart file(s)', exitCode: 64);
    }
    final outSdk =
        argResults!['out-sdk'] as String? ??
        (throw CliException('missing required --out-sdk', exitCode: 64));
    final outCaps =
        argResults!['out-capabilities'] as String? ??
        (throw CliException(
          'missing required --out-capabilities',
          exitCode: 64,
        ));

    final absInputs = <String>[];
    for (final input in inputs) {
      final file = File(input);
      if (!file.existsSync()) {
        throw CliException('input not found: $input', exitCode: 66);
      }
      absInputs.add(p.normalize(file.absolute.path));
    }

    final capsDir = p.dirname(p.normalize(File(outCaps).absolute.path));
    final collection = AnalysisContextCollection(includedPaths: absInputs);
    try {
      final sources = <CapabilitySource>[];
      for (final abs in absInputs) {
        final session = collection.contextFor(abs).currentSession;
        final resolved = await session.getResolvedUnit(abs);
        if (resolved is! ResolvedUnitResult) {
          throw CliException('could not resolve $abs', exitCode: 65);
        }
        final errors = resolved.diagnostics
            .where((e) => e.severity.name == 'ERROR')
            .toList();
        if (errors.isNotEmpty) {
          console.trace(
            '$abs has ${errors.length} analyzer error(s); '
            'generation may be incomplete',
          );
        }
        sources.add(
          CapabilitySource(
            unit: resolved,
            // Emitted as `import '...'` in the generated capabilities file, so
            // it must be POSIX-style regardless of the host platform.
            importPath: toImportPath(p.relative(abs, from: capsDir)),
          ),
        );
      }

      final GeneratedCapabilities generated;
      try {
        generated = CapabilityGenerator(
          sdkFrameworkImport: argResults!['sdk-import'] as String,
        ).generate(sources);
      } on CapabilityGenException catch (e) {
        throw CliException(e.message, exitCode: 65);
      }

      _write(outSdk, generated.sdk);
      _write(outCaps, generated.capabilities);

      console.success('generated $outSdk and $outCaps');
      console.emitJson({'sdk': outSdk, 'capabilities': outCaps});
      return 0;
    } finally {
      await collection.dispose();
    }
  }

  void _write(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(_formatted(contents));
  }

  /// Runs generated source through `dart_style`, so a generated file is
  /// indistinguishable from hand-written code and passes `dart format --set-
  /// exit-if-changed` in the consuming repo. Falls back to the raw source if it
  /// somehow does not parse — a formatting failure must not lose the output.
  String _formatted(String source) {
    try {
      return DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format(source);
    } on Object {
      return source;
    }
  }
}
