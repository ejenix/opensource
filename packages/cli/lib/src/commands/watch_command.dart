// Copyright (c) Ejenix authors. MIT license.

import 'dart:async';
import 'dart:io';

import 'package:ejenix_bundle/bundle.dart';
import 'package:path/path.dart' as p;

import '../base_command.dart';
import '../dev/dev_server.dart';
import '../dev/patch_builder.dart';
import '../dev/watch_session.dart';
import '../util.dart';

/// `ejenix watch <input.dart>` — the fast dev loop.
///
/// Watches the patch source, rebuilds on save, and pushes the fresh signed
/// bundle to a connected app. The measured round trip — save to app-notified —
/// is a few milliseconds (`docs/benchmarks.md`), because the analyzer context is
/// held warm across rebuilds rather than rebuilt each time.
class WatchCommand extends EjenixCommand {
  /// How the command waits for ctrl-c.
  ///
  /// A seam, not a feature: the loop is the whole command, and a loop that only
  /// ends on a real POSIX signal cannot be exercised in-process. Tests replace
  /// this with a future that completes immediately, run the command end to end,
  /// and restore it. Production always uses [untilSigint].
  static Future<void> Function() runUntilInterrupted = untilSigint;

  /// Completes on ctrl-c. The default for [runUntilInterrupted].
  static Future<void> untilSigint() {
    final done = Completer<void>();
    late final StreamSubscription<ProcessSignal> sigint;
    sigint = ProcessSignal.sigint.watch().listen((_) {
      sigint.cancel();
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  WatchCommand() {
    argParser
      ..addOption('signing-key', help: 'Path to the Ed25519 seed file.')
      ..addOption('app-id', help: 'Target application id.')
      ..addOption('output', abbr: 'o', help: 'Also write each build here.')
      ..addOption('port', help: 'Port for the dev server.', defaultsTo: '8787')
      ..addOption(
        'host',
        help:
            'Address to bind. Defaults to loopback; pass 0.0.0.0 to let a '
            'device on your network reach it.',
        defaultsTo: '127.0.0.1',
      )
      ..addMultiOption(
        'watch',
        help:
            'Extra directory to watch (repeatable). The source file’s own '
            'directory is always watched.',
      )
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
      ..addFlag(
        'serve',
        help: 'Serve the patch over HTTP for a connected app.',
        defaultsTo: true,
      );
  }

  @override
  String get name => 'watch';

  @override
  String get description =>
      'Watch a patch, rebuild on save, and push it to a connected app.';

  @override
  String get invocation =>
      'ejenix watch <input.dart> --signing-key <key> --app-id <id>';

  @override
  Future<int> execute() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      throw CliException('missing input .dart file', exitCode: 64);
    }
    final input = File(rest.first);
    if (!input.existsSync()) {
      throw CliException('input not found: ${rest.first}', exitCode: 66);
    }
    final keyPath =
        argResults!['signing-key'] as String? ??
        (throw CliException('missing required --signing-key', exitCode: 64));
    final appId =
        argResults!['app-id'] as String? ??
        (throw CliException('missing required --app-id', exitCode: 64));
    final port =
        int.tryParse(argResults!['port'] as String) ??
        (throw CliException('--port must be a number', exitCode: 64));

    final host = argResults!['host'] as String;
    final sourcePath = input.absolute.path;
    final output = argResults!['output'] as String?;
    final serve = argResults!['serve'] as bool;

    // Watch the source's directory plus any extra roots — a patch usually
    // imports a patch SDK from a sibling directory, and editing that must
    // rebuild too.
    final roots = <String>{
      input.parent.absolute.path,
      for (final dir in argResults!['watch'] as List<String>)
        Directory(dir).absolute.path,
    };

    final server = PatchDevServer(onLog: (m) => console.trace(m));
    var first = true;

    // This command creates the builder, so this command disposes it (see
    // WatchSession.stop).
    final builder = PatchBuilder(
      sourcePath: sourcePath,
      signer: Signer.fromSeed(readSeedFile(keyPath)),
      metadata: BundleMetadata(
        targetAppId: appId,
        targetFlutterVersion: argResults!['flutter-version'] as String,
        minSdk: argResults!['min-sdk'] as String,
      ),
      roots: roots.toList(),
    );

    final session = WatchSession(
      builder: builder,
      server: server,
      roots: roots.toList(),
      serve: serve,
      outputPath: output,
      onBuild: (build) {
        _report(build, server, serve, first: first);
        first = false;
      },
    );

    try {
      await session.start(port: port, host: host);
      if (serve) {
        console.info('dev server → http://$host:${server.port}');
        if (host != '127.0.0.1' && host != 'localhost') {
          // Say it plainly: this now serves signed bytecode to anyone who can
          // reach the machine. Fine on a home LAN to test a phone; not fine on
          // a café network.
          console.warn(
            'bound to $host — reachable by anything on your network',
          );
        }
        console.trace('  GET /patch.bundle   the signed patch');
        console.trace('  GET /events         reload notifications (SSE)');
      }
      console.info('watching ${p.relative(sourcePath)} — ctrl-c to stop');

      await runUntilInterrupted();

      console.info('stopped');
      return 0;
    } on StateError catch (e) {
      throw CliException(e.message, exitCode: 66);
    } finally {
      // This command created the builder, so this command disposes it.
      await session.stop();
      await builder.dispose();
    }
  }

  /// Prints one build. A compile error is reported but does not stop the loop:
  /// the app keeps running the last good patch while you fix the typo.
  void _report(
    PatchBuild build,
    PatchDevServer server,
    bool serve, {
    required bool first,
  }) {
    if (!build.ok) {
      for (final error in build.errors) {
        console.error(error.toString());
      }
      console.warn(
        '${build.errors.length} error(s) — keeping the last good patch',
      );
      return;
    }
    console.success(
      '${first ? 'built' : 'rebuilt'} ${build.functionCount} function(s) '
      'in ${build.total.inMilliseconds} ms '
      '(compile ${build.compile.inMilliseconds} ms, '
      'sign ${build.sign.inMilliseconds} ms)'
      '${serve ? ' → ${server.clientCount} app(s)' : ''}',
    );
  }
}
