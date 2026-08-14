// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_delta/delta.dart';

import '../base_command.dart';
import '../util.dart';

/// `ejenix build-delta --base <base.bundle> <input.dart> -o <delta.bundle>` —
/// compile, sign, and diff against a base to produce a small delta bundle.
class CompileDeltaCommand extends EjenixCommand {
  CompileDeltaCommand() {
    argParser
      ..addOption('base', help: 'The base bundle to diff against.')
      ..addOption('output', abbr: 'o', help: 'Output delta bundle path.')
      ..addOption('signing-key', help: 'Path to the Ed25519 seed file.')
      ..addOption('app-id', help: 'Target application id.')
      ..addOption('flutter-version', defaultsTo: '0.0.0')
      ..addOption('min-sdk', defaultsTo: '1.0.0')
      ..addOption('compiler-version', defaultsTo: '0.1.0');
  }

  @override
  String get name => 'build-delta';

  /// `compile-delta` is the pre-1.0 name, kept so existing scripts keep working.
  @override
  List<String> get aliases => const ['compile-delta'];

  @override
  String get description =>
      'Compile a Dart file and emit a delta patch against a base.';

  @override
  String get invocation =>
      'ejenix build-delta --base <base.bundle> <input.dart> -o <delta.bundle> '
      '--signing-key <key> --app-id <id>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty)
      throw CliException('missing input .dart file', exitCode: 64);
    final input = rest.first;
    final basePath =
        argResults!['base'] as String? ??
        (throw CliException('missing required --base', exitCode: 64));
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
    final base = loadBundle(basePath);
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

    final target = Bundle.sign(
      module: result.moduleOrThrow,
      metadata: BundleMetadata(
        targetAppId: appId,
        targetFlutterVersion: argResults!['flutter-version'] as String,
        minSdk: argResults!['min-sdk'] as String,
      ),
      signer: signer,
      compilerVersion: argResults!['compiler-version'] as String,
    );
    final delta = DeltaBundle.create(
      base: base,
      target: target,
      signer: signer,
      compilerVersion: argResults!['compiler-version'] as String,
    );

    final deltaBytes = delta.encode();
    final fullBytes = target.encode().length;
    File(output).writeAsBytesSync(deltaBytes);
    final ratio = (deltaBytes.length / fullBytes * 100).toStringAsFixed(1);
    console.success(
      'wrote delta -> $output '
      '(${deltaBytes.length} bytes, $ratio% of the $fullBytes-byte full '
      'bundle)',
    );
    console.info('base:   ${formatUuid(base.bundleId)}');
    console.info('target: ${formatUuid(target.bundleId)}');
    console.emitJson({
      'output': output,
      'baseId': formatUuid(base.bundleId),
      'targetId': formatUuid(target.bundleId),
      'deltaBytes': deltaBytes.length,
      'fullBytes': fullBytes,
      'ratioPercent': double.parse(ratio),
    });
    return 0;
  }
}
