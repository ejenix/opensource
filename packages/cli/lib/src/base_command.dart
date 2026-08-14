// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:args/command_runner.dart';

import 'console.dart';

/// Provides the sinks and terminal state a [Console] needs. Implemented by the
/// runner so command output can be redirected in tests.
abstract interface class ConsoleHost {
  StringSink get out;
  StringSink get err;
  bool get isOutputTerminal;
}

/// An expected, user-facing failure. Its [exitCode] becomes the process exit
/// code (following the sysexits.h conventions: 64 usage, 65 data, 66 no input).
class CliException implements Exception {
  CliException(this.message, {this.exitCode = 1});
  final String message;
  final int exitCode;
}

/// The environment variable a CI secret store is expected to set.
const _tokenEnvVar = 'EJENIX_TOKEN';

/// Base class for `ejenix` subcommands.
///
/// Subclasses implement [execute]; [run] wraps it so a [CliException] is printed
/// and mapped to an exit code rather than crashing. The [console] reflects the
/// global `--json`, `--verbose`, and `--color` flags.
abstract class EjenixCommand extends Command<int> {
  Console? _console;

  /// The output console, honoring global flags.
  Console get console => _console ??= _buildConsole();

  Console _buildConsole() {
    final global = globalResults!;
    final host = runner! as ConsoleHost;
    final colorMode = global['color'] as String;
    final useColor =
        colorMode == 'always' || (colorMode == 'auto' && host.isOutputTerminal);
    return Console(
      out: host.out,
      err: host.err,
      useColor: useColor,
      json: global['json'] as bool,
      verbose: global['verbose'] as bool,
    );
  }

  /// Returns the value of required option [name], or throws a usage error.
  String requireOption(String name) =>
      argResults![name] as String? ??
      (throw CliException('missing required --$name', exitCode: 64));

  /// Registers `--token` and the safer ways to supply it.
  ///
  /// Call from a command that authenticates to a control plane, then read the
  /// value with [requireToken].
  void addTokenOptions({required String help}) {
    argParser
      ..addOption(
        'token',
        help:
            '$help Discouraged: a value here is recorded in shell history and '
            'is visible to any process that can read the process list. Prefer '
            '--token-file, --token-stdin, or $_tokenEnvVar.',
      )
      ..addOption(
        'token-file',
        help: 'Read the token from the first line of this file.',
      )
      ..addFlag(
        'token-stdin',
        negatable: false,
        help: 'Read the token from stdin (for `… | ejenix …`).',
      );
  }

  /// Resolves the control-plane token, preferring sources that do not leak it.
  ///
  /// A token on the command line is exposed twice over: the shell records it in
  /// history, and on Linux any local user can read it out of `/proc/<pid>/cmdline`
  /// while the command runs. Neither is fixable after the fact — the token has
  /// to arrive by another route.
  ///
  /// Order, safest explicit source first:
  ///
  /// 1. `--token-file` — the token never appears in an argument list.
  /// 2. `--token-stdin` — same, and leaves nothing on disk.
  /// 3. `--token` — honoured, with a warning, so existing scripts keep working.
  /// 4. `$EJENIX_TOKEN`, then `$EJENIX_ADMIN_KEY` — what CI secret stores set.
  ///
  /// Explicit flags beat the environment so a one-off command can override a
  /// shell that already has a token exported.
  String requireToken({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;

    final file = argResults!['token-file'] as String?;
    if (file != null) {
      final handle = File(file);
      if (!handle.existsSync()) {
        throw CliException('token file not found: $file', exitCode: 66);
      }
      final value = _firstLine(handle.readAsStringSync());
      if (value.isEmpty) throw CliException('token file is empty: $file');
      return value;
    }

    if (argResults!['token-stdin'] as bool) {
      final value = _firstLine(stdin.readLineSync() ?? '');
      if (value.isEmpty) throw CliException('no token on stdin');
      return value;
    }

    final inline = argResults!['token'] as String?;
    if (inline != null) {
      console.warn(
        '--token puts the token in your shell history and in the process list. '
        'Prefer --token-file, --token-stdin, or $_tokenEnvVar.',
      );
      return inline;
    }

    for (final name in const [_tokenEnvVar, 'EJENIX_ADMIN_KEY']) {
      final value = env[name];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }

    throw CliException(
      'no API token. Pass --token-file <path>, pipe one with --token-stdin, '
      'set $_tokenEnvVar, or (discouraged) pass --token.',
      exitCode: 64,
    );
  }

  static String _firstLine(String s) => s.split('\n').first.trim();

  /// The command body. Throw [CliException] on an expected failure.
  Future<int> execute();

  @override
  Future<int> run() async {
    try {
      return await execute();
    } on CliException catch (e) {
      console.error(e.message);
      return e.exitCode;
    }
  }
}
