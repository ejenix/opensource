// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';

import 'base_command.dart';
import 'commands/app_command.dart';
import 'commands/bench_command.dart';
import 'commands/compile_command.dart';
import 'commands/compile_delta_command.dart';
import 'commands/doctor_command.dart';
import 'commands/gen_command.dart';
import 'commands/init_command.dart';
import 'commands/inspect_command.dart';
import 'commands/keygen_command.dart';
import 'commands/promote_command.dart';
import 'commands/publish_command.dart';
import 'commands/rollback_command.dart';
import 'commands/scaffold_command.dart';
import 'commands/verify_command.dart';
import 'commands/watch_command.dart';

/// The released `ejenix` version. Kept in step with `packages/cli/pubspec.yaml`;
/// bump both together at a tagged release.
const ejenixVersion = '0.1.0';

/// The `ejenix` command runner.
///
/// Output sinks and terminal detection are injectable so the whole CLI can be
/// driven and captured in tests. Global flags `--verbose`, `--json`, and
/// `--color` apply to every subcommand.
class EjenixRunner extends CommandRunner<int> implements ConsoleHost {
  EjenixRunner({StringSink? out, StringSink? err, bool? isOutputTerminal})
    : out = out ?? stdout,
      err = err ?? stderr,
      isOutputTerminal = isOutputTerminal ?? _detectTerminal(),
      super('ejenix', 'Ejenix — the live-update toolchain for Flutter.') {
    argParser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Verbose diagnostic output.',
      )
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the ejenix version and exit.',
      )
      ..addFlag(
        'json',
        negatable: false,
        help: 'Emit machine-readable JSON on stdout.',
      )
      ..addOption(
        'color',
        allowed: ['auto', 'always', 'never'],
        defaultsTo: 'auto',
        help: 'Colorize output.',
      );

    addCommand(AppCommand());
    addCommand(InitCommand());
    addCommand(KeygenCommand());
    addCommand(CompileCommand());
    addCommand(CompileDeltaCommand());
    addCommand(GenCommand());
    addCommand(ScaffoldCommand());
    addCommand(WatchCommand());
    addCommand(InspectCommand());
    addCommand(VerifyCommand());
    addCommand(PublishCommand());
    addCommand(PromoteCommand());
    addCommand(RollbackCommand());
    addCommand(DoctorCommand());
    addCommand(BenchCommand());
  }

  @override
  final StringSink out;

  @override
  final StringSink err;

  @override
  final bool isOutputTerminal;

  /// Handles the global `--version` flag before dispatching to a command, so
  /// `ejenix --version` works with no subcommand.
  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] as bool) {
      out.writeln('ejenix $ejenixVersion');
      return 0;
    }
    return super.runCommand(topLevelResults);
  }

  static bool _detectTerminal() {
    try {
      return stdout.hasTerminal;
    } on Object {
      return false;
    }
  }
}
