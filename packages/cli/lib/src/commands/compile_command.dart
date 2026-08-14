// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_compiler/compiler.dart';

import '../base_command.dart';
import '../util.dart';

/// `ejenix build <input.dart> -o <out> --signing-key <key>` — compile + sign.
class CompileCommand extends EjenixCommand {
  CompileCommand() {
    argParser
      ..addOption('output', abbr: 'o', help: 'Output bundle path.')
      ..addOption('signing-key', help: 'Path to the Ed25519 seed file.')
      ..addOption('app-id', help: 'Target application id.')
      ..addOption(
        'flutter-version',
        help: 'Target Flutter version.',
        defaultsTo: '0.0.0',
      )
      ..addOption(
        'min-sdk',
        help: 'Minimum interpreter SDK.',
        defaultsTo: '1.0.0',
      )
      ..addOption(
        'compiler-version',
        help: 'Compiler version recorded in the bundle.',
        defaultsTo: '0.1.0',
      );
  }

  @override
  String get name => 'build';

  /// `compile` is the pre-1.0 name, kept so existing scripts keep working.
  @override
  List<String> get aliases => const ['compile'];

  @override
  String get description => 'Compile a Dart source file into a signed patch.';

  @override
  String get invocation =>
      'ejenix build <input.dart> -o <output.bundle> --signing-key <key> '
      '--app-id <id>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty)
      throw CliException('missing input .dart file', exitCode: 64);
    final input = rest.first;
    final output =
        argResults!['output'] as String? ??
        (throw CliException('missing required --output', exitCode: 64));
    final keyPath =
        argResults!['signing-key'] as String? ??
        (throw CliException('missing required --signing-key', exitCode: 64));
    final appId =
        argResults!['app-id'] as String? ??
        (throw CliException('missing required --app-id', exitCode: 64));

    if (!File(input).existsSync()) {
      throw CliException('input not found: $input', exitCode: 66);
    }
    final signer = Signer.fromSeed(readSeedFile(keyPath));

    console.trace('compiling $input');
    final result = await Compiler().compileFile(File(input).absolute.path);
    if (result.hasErrors) {
      for (final diagnostic in result.errors) {
        console.error(diagnostic.toString());
      }
      throw CliException(
        'compilation failed with ${result.errors.length} error(s)',
        exitCode: 65,
      );
    }
    final module = result.moduleOrThrow;

    final bundle = Bundle.sign(
      module: module,
      metadata: BundleMetadata(
        targetAppId: appId,
        targetFlutterVersion: argResults!['flutter-version'] as String,
        minSdk: argResults!['min-sdk'] as String,
      ),
      signer: signer,
      compilerVersion: argResults!['compiler-version'] as String,
    );

    final bytes = bundle.encode();
    File(output).writeAsBytesSync(bytes);
    console.success(
      'compiled ${module.functions.length} function(s) '
      '-> $output (${bytes.length} bytes)',
    );
    console.info('bundle-id: ${formatUuid(bundle.bundleId)}');
    console.emitJson({
      'output': output,
      'bundleId': formatUuid(bundle.bundleId),
      'functions': module.functions.length,
      'bytes': bytes.length,
    });
    return 0;
  }
}
