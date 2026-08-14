// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p_lib;
import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_cli/src/commands/compile_command.dart';
import 'package:ejenix_cli/src/commands/compile_delta_command.dart';
import 'package:ejenix_cli/src/commands/inspect_command.dart';
import 'package:ejenix_cli/src/commands/keygen_command.dart';
import 'package:ejenix_cli/src/commands/verify_command.dart';
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
  String p(String name) => '${dir.path}/$name';

  setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_cli_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> keygen(String name) async {
    final r = await runCli(['keygen', '-o', p(name)]);
    expect(r.code, 0, reason: r.err);
  }

  Future<void> writePatch(String name, String source) async =>
      File(p(name)).writeAsStringSync(source);

  group('--version', () {
    test('prints the version and exits 0, with no subcommand', () async {
      final r = await runCli(['--version']);
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), 'ejenix $ejenixVersion');
    });

    test('reported version matches the cli pubspec', () {
      // The one place the version is declared must stay in step with the
      // package it ships as, or `--version` would lie. Resolve the cli pubspec
      // whether the suite runs from the package dir (coverage.sh) or the repo
      // root (`dart test packages/...`).
      // Package path first: from the repo root the version-less workspace
      // pubspec also exists, but only the cli one carries a `version:`.
      final pubspec = [
        File('packages/cli/pubspec.yaml'),
        File('pubspec.yaml'),
      ].firstWhere((f) => f.existsSync()).readAsStringSync();
      final declared = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1);
      expect(ejenixVersion, declared);
    });
  });

  group('keygen', () {
    test('writes seed and public key files', () async {
      final r = await runCli(['keygen', '-o', p('k.key')]);
      expect(r.code, 0);
      expect(File(p('k.key')).existsSync(), isTrue);
      expect(File(p('k.key.pub')).existsSync(), isTrue);
      expect(r.out, contains('public key'));
    });

    test('the private seed is owner-only on disk', () async {
      // The one unrecoverable secret in the toolchain: it is the authority
      // every shipped binary was built to trust, and it cannot be revoked
      // without a store release. A default-umask write leaves it world-readable
      // on a typical machine, so this is checked, not assumed.
      await keygen('k.key');

      final mode = File(p('k.key')).statSync().mode;
      expect(
        mode & 0x3F,
        0,
        reason:
            'seed is ${File(p('k.key')).statSync().modeString()}; '
            'group/other bits must be clear',
      );
    }, testOn: '!windows'); // NTFS has no POSIX mode; see _restrictToOwner.

    test('the public key stays readable', () async {
      // The guard against over-correcting: locking down the .pub file too would
      // break every CI step and reviewer that needs to read it.
      await keygen('k.key');
      expect(File(p('k.key.pub')).readAsStringSync().trim(), hasLength(64));
    });

    test('no temporary file is left beside the key', () async {
      // The seed is written through a temp file and renamed; a leftover would
      // be a second copy of the secret, and possibly one without the
      // restricted mode.
      await keygen('k.key');
      expect(File('${p('k.key')}.tmp').existsSync(), isFalse);
      expect(
        // p_lib.basename, not split('/') — Windows separates with a backslash,
        // so splitting on '/' there yields the whole absolute path.
        Directory(
          dir.path,
        ).listSync().map((e) => p_lib.basename(e.path)).toSet(),
        {'k.key', 'k.key.pub'},
      );
    });

    test('the written seed still round-trips through signing', () async {
      // Permissions work must not corrupt the bytes: a key that is safe but
      // wrong is worse than one that is merely exposed.
      await keygen('k.key');
      final seed = File(p('k.key')).readAsStringSync().trim();
      expect(seed, hasLength(64));
      expect(int.tryParse(seed.substring(0, 8), radix: 16), isNotNull);
    });

    test('refuses to overwrite without --force', () async {
      await keygen('k.key');
      final r = await runCli(['keygen', '-o', p('k.key')]);
      expect(r.code, 1);
      expect(r.err, contains('already exist'));
    });

    test('--json emits structured output only', () async {
      final r = await runCli(['--json', 'keygen', '-o', p('k.key')]);
      final json = jsonDecode(r.out) as Map;
      expect(json['publicKeyHex'], isA<String>());
      expect(r.out, isNot(contains('✓')));
    });

    test('missing --out is a usage error', () async {
      final r = await runCli(['keygen']);
      expect(r.code, 64);
    });
  });

  group('compile → inspect → verify', () {
    test('the happy path round-trips', () async {
      await keygen('signing.key');
      await writePatch(
        'patch.dart',
        'int add(int a, int b) => a + b;\nint main() => add(20, 22);\n',
      );

      final compile = await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('patch.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'com.example.app',
      ]);
      expect(compile.code, 0, reason: compile.err);
      expect(File(p('patch.bundle')).existsSync(), isTrue);

      final inspect = await runCli(['inspect', p('patch.bundle')]);
      expect(inspect.code, 0);
      expect(inspect.out, contains('com.example.app'));
      expect(inspect.out, contains('function F0 add'));

      final verify = await runCli([
        'verify',
        p('patch.bundle'),
        '--key',
        p('signing.key.pub'),
      ]);
      expect(verify.code, 0);
      expect(verify.out, contains('valid'));
    });

    test('verify fails against a foreign key', () async {
      await keygen('signing.key');
      await keygen('other.key');
      await writePatch('patch.dart', 'int main() => 1;');
      await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('patch.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      final verify = await runCli([
        'verify',
        p('patch.bundle'),
        '--key',
        p('other.key.pub'),
      ]);
      expect(verify.code, 1);
      expect(verify.err, contains('untrustedKey'));
    });

    test('inspect --json lists functions', () async {
      await keygen('signing.key');
      await writePatch('patch.dart', 'int main() => 7;');
      await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('b.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      final r = await runCli(['--json', 'inspect', p('b.bundle')]);
      final json = jsonDecode(r.out) as Map;
      expect((json['functions'] as List).single['name'], 'main');
    });
  });

  group('compile errors', () {
    test('a compile error exits 65 and prints diagnostics', () async {
      await keygen('signing.key');
      await writePatch('bad.dart', 'int topLevel = 0;');
      final r = await runCli([
        'compile',
        p('bad.dart'),
        '-o',
        p('out.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      expect(r.code, 65);
      expect(r.err, contains('not yet supported'));
    });

    test('a missing input file exits 66', () async {
      await keygen('signing.key');
      final r = await runCli([
        'compile',
        p('nope.dart'),
        '-o',
        p('out.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      expect(r.code, 66);
    });

    test('a missing --app-id is a usage error', () async {
      await keygen('signing.key');
      await writePatch('patch.dart', 'int main() => 1;');
      final r = await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('out.bundle'),
        '--signing-key',
        p('signing.key'),
      ]);
      expect(r.code, 64);
    });
  });

  group('verify errors', () {
    test('a malformed bundle exits 65', () async {
      await keygen('k.key');
      File(p('junk.bundle')).writeAsBytesSync([0, 1, 2, 3]);
      final r = await runCli([
        'verify',
        p('junk.bundle'),
        '--key',
        p('k.key.pub'),
      ]);
      expect(r.code, 65);
    });
  });

  group('compile-delta', () {
    // A base large enough that a one-line change yields a genuinely small
    // delta (tiny bundles are dominated by fixed signature/hash overhead).
    String bigProgram(int mainValue) {
      final b = StringBuffer();
      for (var i = 0; i < 40; i++) {
        b.writeln('int f$i(int x) => x + $i;');
      }
      b.writeln('int main() => f0($mainValue) + f39(1);');
      return b.toString();
    }

    test('produces a delta smaller than the full bundle', () async {
      await keygen('signing.key');
      await writePatch('base.dart', bigProgram(1));
      await runCli([
        'compile',
        p('base.dart'),
        '-o',
        p('base.bundle'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      await writePatch('target.dart', bigProgram(2));
      final r = await runCli([
        '--json',
        'compile-delta',
        p('target.dart'),
        '--base',
        p('base.bundle'),
        '-o',
        p('patch.delta'),
        '--signing-key',
        p('signing.key'),
        '--app-id',
        'app',
      ]);
      expect(r.code, 0, reason: r.err);
      final json = jsonDecode(r.out) as Map;
      expect(json['deltaBytes'], lessThan(json['fullBytes'] as int));
      expect(File(p('patch.delta')).existsSync(), isTrue);
    });
  });

  group('doctor / init / bench', () {
    test('doctor reports a healthy environment', () async {
      final r = await runCli(['doctor']);
      expect(r.code, 0);
      expect(r.out, contains('dart'));
    });

    test('doctor fails on a bad signing key', () async {
      File(p('bad.key')).writeAsStringSync('not-hex');
      final r = await runCli(['doctor', '--signing-key', p('bad.key')]);
      expect(r.code, 1);
    });

    test('init scaffolds a starter project', () async {
      final r = await runCli(['init', p('proj')]);
      expect(r.code, 0);
      expect(File(p('proj/patch.dart')).existsSync(), isTrue);
      expect(File(p('proj/README.md')).existsSync(), isTrue);
    });

    test('bench runs and reports throughput', () async {
      final r = await runCli(['--json', 'bench', '--iterations', '1']);
      expect(r.code, 0);
      final json = jsonDecode(r.out) as Map;
      expect((json['benchmarks'] as List).length, 3);
    });
  });

  group('argument and IO errors', () {
    test('compile with a missing signing-key file exits 66', () async {
      await writePatch('patch.dart', 'int main() => 1;');
      final r = await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('out.bundle'),
        '--signing-key',
        p('nope.key'),
        '--app-id',
        'app',
      ]);
      expect(r.code, 66);
    });

    test(
      'compile missing --output and --signing-key are usage errors',
      () async {
        await writePatch('patch.dart', 'int main() => 1;');
        expect((await runCli(['compile', p('patch.dart')])).code, 64);
        expect(
          (await runCli([
            'compile',
            p('patch.dart'),
            '-o',
            p('o.bundle'),
          ])).code,
          64,
        );
      },
    );

    test('verify with a nonexistent bundle exits 66', () async {
      await keygen('k.key');
      final r = await runCli([
        'verify',
        p('gone.bundle'),
        '--key',
        p('k.key.pub'),
      ]);
      expect(r.code, 66);
    });

    test('verify with a bad-hex key exits 65', () async {
      await keygen('k.key');
      await writePatch('patch.dart', 'int main() => 1;');
      await runCli([
        'compile',
        p('patch.dart'),
        '-o',
        p('b.bundle'),
        '--signing-key',
        p('k.key'),
        '--app-id',
        'app',
      ]);
      final r = await runCli(['verify', p('b.bundle'), '--key', 'zz-not-hex']);
      expect(r.code, 65);
    });

    test('verify with no --key is a usage error', () async {
      final r = await runCli(['verify', p('whatever.bundle')]);
      expect(r.code, 64);
    });

    test('compile-delta reports missing arguments', () async {
      await writePatch('t.dart', 'int main() => 1;');
      // Missing --base.
      expect((await runCli(['compile-delta', p('t.dart')])).code, 64);
      // No input at all.
      expect((await runCli(['compile-delta'])).code, 64);
    });

    test('compile-delta with a nonexistent input exits 66', () async {
      await keygen('k.key');
      await writePatch('base.dart', 'int main() => 1;');
      await runCli([
        'compile',
        p('base.dart'),
        '-o',
        p('base.bundle'),
        '--signing-key',
        p('k.key'),
        '--app-id',
        'app',
      ]);
      final r = await runCli([
        'compile-delta',
        p('missing.dart'),
        '--base',
        p('base.bundle'),
        '-o',
        p('d.delta'),
        '--signing-key',
        p('k.key'),
        '--app-id',
        'app',
      ]);
      expect(r.code, 66);
    });
  });

  group('usage', () {
    test('an unknown command is a usage error', () async {
      final r = await runCli(['frobnicate']);
      expect(r.code, 64);
    });

    test('commands expose their invocation strings', () {
      expect(CompileCommand().invocation, contains('ejenix build'));
      expect(CompileDeltaCommand().invocation, contains('ejenix build-delta'));
      expect(VerifyCommand().invocation, contains('ejenix verify'));
      expect(InspectCommand().invocation, contains('ejenix inspect'));
      expect(KeygenCommand().invocation, contains('ejenix keygen'));
    });
  });
}
