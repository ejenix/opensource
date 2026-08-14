// Copyright (c) Ejenix authors. MIT license.

/// The publish-side gate: a patch that needs a capability the shipped app does
/// not register must fail CI, not a user's phone.
///
/// A patch is signed and structurally valid whether or not the app can run it —
/// signature verification says the bytes are authentic, nothing more. The
/// capability check is the separate question, and this is where it gets asked.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:ejenix_cli/cli.dart';
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
  String p(String n) => '${dir.path}/$n';

  setUp(() => dir = Directory.systemTemp.createTempSync('ejenix_capgate'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Builds a signed patch that calls [capability] as a host global, the way a
  /// real patch reaches an app's `@Patchable` code through its generated SDK.
  Future<void> buildPatchNeeding(String capability) async {
    expect((await runCli(['keygen', '-o', p('k')])).code, 0);
    File(p('sdk.dart')).writeAsStringSync('external int $capability();\n');
    File(
      p('patch.dart'),
    ).writeAsStringSync("import 'sdk.dart';\nint main() => $capability();\n");
    final r = await runCli([
      'build',
      p('patch.dart'),
      '-o',
      p('patch.bundle'),
      '--signing-key',
      p('k'),
      '--app-id',
      'com.example.app',
    ]);
    expect(r.code, 0, reason: r.err);
  }

  void writeManifest(String name, List<String> globals) =>
      File(p(name)).writeAsStringSync(jsonEncode({'globals': globals}));

  test('inspect reports the capabilities a patch requires', () async {
    await buildPatchNeeding('blogsCount');
    final r = await runCli(['inspect', p('patch.bundle')]);
    expect(r.code, 0, reason: r.err);
    expect(r.out, contains('blogsCount'));
    expect(r.out, contains('needs-capabilities'));
  });

  test(
    'verify fails when the app does not register a needed capability',
    () async {
      await buildPatchNeeding('blogsCount');
      writeManifest('m.json', ['Text', 'Column']);

      final r = await runCli([
        'verify',
        p('patch.bundle'),
        '--key',
        p('k.pub'),
        '--capabilities',
        p('m.json'),
      ]);

      // EX_DATAERR: the bundle is authentic but unusable here. A non-zero exit is
      // the whole point — this is what fails the build before publishing.
      expect(r.code, 65, reason: r.out + r.err);
      expect(r.err, contains('blogsCount'));
      // The remedy, not just the symptom.
      expect(r.err, contains('Ship a build'));
    },
  );

  test('verify passes once the manifest includes it', () async {
    await buildPatchNeeding('blogsCount');
    writeManifest('m.json', ['Text', 'blogsCount']);

    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('k.pub'),
      '--capabilities',
      p('m.json'),
    ]);
    expect(r.code, 0, reason: r.out + r.err);
    expect(r.out, contains('runnable'));
  });

  test('a bare JSON list is accepted as a manifest', () async {
    await buildPatchNeeding('blogsCount');
    File(p('m.json')).writeAsStringSync('["blogsCount"]');
    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('k.pub'),
      '--capabilities',
      p('m.json'),
    ]);
    expect(r.code, 0, reason: r.out + r.err);
  });

  test(
    'without --capabilities, verify still only checks the signature',
    () async {
      // The flag is additive. Existing pipelines that verify without it must
      // behave exactly as before, or upgrading breaks every release job.
      await buildPatchNeeding('blogsCount');
      final r = await runCli([
        'verify',
        p('patch.bundle'),
        '--key',
        p('k.pub'),
      ]);
      expect(r.code, 0, reason: r.err);
      expect(r.out, contains('valid'));
    },
  );

  test('an untrusted signature fails before the capability check', () async {
    await buildPatchNeeding('blogsCount');
    expect((await runCli(['keygen', '-o', p('other')])).code, 0);
    writeManifest('m.json', ['blogsCount']);

    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('other.pub'),
      '--capabilities',
      p('m.json'),
    ]);
    // Authenticity is the stronger claim; it must not be masked by a passing
    // capability check.
    expect(r.code, isNot(0));
    expect(r.out + r.err, isNot(contains('runnable')));
  });

  test('a missing manifest file is a usage error, not a silent pass', () async {
    await buildPatchNeeding('blogsCount');
    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('k.pub'),
      '--capabilities',
      p('nope.json'),
    ]);
    expect(r.code, 66, reason: r.out + r.err); // EX_NOINPUT
  });

  test('a malformed manifest is rejected, not treated as empty', () async {
    // Treating unreadable input as "no capabilities" would fail every patch;
    // treating it as "all capabilities" would pass every patch. Both are worse
    // than stopping.
    await buildPatchNeeding('blogsCount');
    File(p('m.json')).writeAsStringSync('{not json');
    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('k.pub'),
      '--capabilities',
      p('m.json'),
    ]);
    expect(r.code, 65, reason: r.out + r.err);
  });

  test('a patch needing nothing passes against any manifest', () async {
    expect((await runCli(['keygen', '-o', p('k')])).code, 0);
    File(p('patch.dart')).writeAsStringSync('int main() => 42;\n');
    expect(
      (await runCli([
        'build',
        p('patch.dart'),
        '-o',
        p('patch.bundle'),
        '--signing-key',
        p('k'),
        '--app-id',
        'com.example.app',
      ])).code,
      0,
    );
    writeManifest('m.json', <String>[]);
    final r = await runCli([
      'verify',
      p('patch.bundle'),
      '--key',
      p('k.pub'),
      '--capabilities',
      p('m.json'),
    ]);
    expect(r.code, 0, reason: r.out + r.err);
  });
}
