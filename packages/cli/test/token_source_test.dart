// Copyright (c) Ejenix authors. MIT license.

/// A control-plane token passed as `--token` leaks twice over: the shell writes
/// it to history, and while the command runs any local user can read it out of
/// the process list (`ps`, or `/proc/<pid>/cmdline` on Linux). Neither is
/// fixable afterwards — by the time you notice, the token is already recorded.
///
/// So the token has to be able to arrive by a route that never puts it in an
/// argument vector. `--token` still works, because breaking every existing
/// script would be its own outage, but it warns and it is last among the
/// explicit sources.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_server/server.dart';
import 'package:test/test.dart';

typedef CliResult = ({int code, String out, String err});

Future<CliResult> runCli(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final runner = EjenixRunner(out: out, err: err, isOutputTerminal: false);
  int code;
  try {
    code = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    err.writeln(e);
    code = 64;
  }
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  late Directory dir;
  late HttpServer server;
  late String baseUrl;
  String p(String name) => '${dir.path}/$name';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ejenix_token_test');
    final plane = ControlPlane(
      store: InMemoryStore(),
      adminApiKey: 'admin-token',
      deliverySigner: Signer.generate(),
      random: Random(7),
    );
    server = await serve(plane, address: 'localhost', port: 0);
    baseUrl = 'http://localhost:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  /// `app list` is the cheapest authenticated call; it only needs a token.
  Future<CliResult> appList(List<String> tokenArgs) =>
      runCli(['app', 'list', '--server', baseUrl, ...tokenArgs]);

  group('--token-file', () {
    test(
      'authenticates without the token entering the argument list',
      () async {
        File(p('t')).writeAsStringSync('admin-token\n');
        final r = await appList(['--token-file', p('t')]);
        expect(r.code, 0, reason: r.err);
      },
    );

    test('tolerates a trailing newline, which every editor adds', () async {
      File(p('t')).writeAsStringSync('admin-token\n\n');
      expect((await appList(['--token-file', p('t')])).code, 0);
    });

    test(
      'a missing file is EX_NOINPUT, not a confusing auth failure',
      () async {
        final r = await appList(['--token-file', p('nope')]);
        expect(r.code, 66);
        expect(r.err, contains('token file not found'));
      },
    );

    test(
      'an empty file is reported as empty, not sent as a blank token',
      () async {
        // Sending "" would come back as a 401 and send the operator hunting
        // through server logs for a problem that is on their disk.
        File(p('t')).writeAsStringSync('\n');
        final r = await appList(['--token-file', p('t')]);
        expect(r.err, contains('empty'));
        expect(r.code, isNot(0));
      },
    );

    test(
      'it beats --token, so the safe source wins when both are given',
      () async {
        File(p('t')).writeAsStringSync('admin-token');
        final r = await appList(['--token-file', p('t'), '--token', 'wrong']);
        expect(r.code, 0, reason: r.err);
      },
    );
  });

  group('--token', () {
    test('still works, so existing scripts keep running', () async {
      expect((await appList(['--token', 'admin-token'])).code, 0);
    });

    test('warns about history and the process list', () async {
      final r = await appList(['--token', 'admin-token']);
      expect(r.err, contains('shell history'));
      expect(r.err, contains('process list'));
    });

    test(
      'the warning goes to stderr, leaving --json output parseable',
      () async {
        // An operator piping `--json` into jq must not have the warning land in
        // the middle of the document.
        final r = await runCli([
          '--json',
          'app',
          'list',
          '--server',
          baseUrl,
          '--token',
          'admin-token',
        ]);
        expect(r.code, 0, reason: r.err);
        expect(() => jsonDecode(r.out), returnsNormally);
        expect(r.out, isNot(contains('warning')));
      },
    );
  });

  group('no token at all', () {
    test('names every way to supply one', () async {
      final r = await appList(const []);
      expect(r.code, 64);
      expect(r.err, contains('--token-file'));
      expect(r.err, contains('--token-stdin'));
      expect(r.err, contains('EJENIX_TOKEN'));
    });
  });

  group('environment', () {
    // Dart cannot mutate its own environment, so this is the one path that has
    // to be exercised through a real subprocess — which is also exactly how CI
    // supplies a token, so the coverage is worth the second or two.
    /// Resolves the CLI entry point from either working directory the suite
    /// runs in: `packages/cli` locally, the repo root under `dart test
    /// packages` in CI. Hard-coding one made this pass locally and fail in CI.
    String entryPoint() {
      for (final candidate in const [
        'bin/ejenix.dart',
        'packages/cli/bin/ejenix.dart',
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
      throw StateError(
        'cannot find bin/ejenix.dart from ${Directory.current.path}',
      );
    }

    Future<ProcessResult> runProcess(Map<String, String> env) => Process.run(
      Platform.resolvedExecutable,
      ['run', entryPoint(), 'app', 'list', '--server', baseUrl],
      environment: env,
    );

    test(
      'EJENIX_TOKEN authenticates with nothing on the command line',
      () async {
        final r = await runProcess({'EJENIX_TOKEN': 'admin-token'});
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'EJENIX_ADMIN_KEY is accepted too, matching the server docs',
      () async {
        // deploy.sh prints EJENIX_ADMIN_KEY; requiring a differently-named
        // variable would make the documented flow fail for no reason.
        final r = await runProcess({'EJENIX_ADMIN_KEY': 'admin-token'});
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
