// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_cli/src/codegen/scaffold.dart';
import 'package:ejenix_cli/src/util.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

typedef CliResult = ({int code, String out, String err});

Future<CliResult> runCli(List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await EjenixRunner(
    out: out,
    err: err,
    isOutputTerminal: false,
  ).run(args);
  return (code: code ?? 0, out: out.toString(), err: err.toString());
}

void main() {
  group('toImportPath', () {
    // A Dart import URI is POSIX-style on every platform. `p.relative` returns
    // a *platform* path, so on Windows the scaffolded patch used to be written
    // with `import '..\patch_sdk/flutter.dart';` — a backslash, which Dart
    // reads as a string escape, not a separator. That broke `ejenix scaffold`
    // and `ejenix gen` for every Windows user.
    //
    // The context is injected here so the Windows case is covered from any
    // machine, instead of only when a Windows CI runner happens to run.
    test('rewrites Windows separators into import separators', () {
      expect(toImportPath(r'..\patch_sdk', context: p.windows), '../patch_sdk');
      expect(
        toImportPath(r'..\..\deep\patch_sdk', context: p.windows),
        '../../deep/patch_sdk',
      );
      expect(toImportPath('patch_sdk', context: p.windows), 'patch_sdk');
    });

    test('leaves POSIX paths untouched', () {
      expect(toImportPath('../patch_sdk', context: p.posix), '../patch_sdk');
      expect(
        toImportPath('../../deep/patch_sdk', context: p.posix),
        '../../deep/patch_sdk',
      );
    });

    test('never emits a backslash into an import', () {
      final windowsRelative = p.windows.relative(
        r'C:\proj\patch_sdk',
        from: r'C:\proj\patches',
      );
      final result = toImportPath(windowsRelative, context: p.windows);
      expect(result, '../patch_sdk');
      expect(result, isNot(contains(r'\')));
    });
  });

  test('pascalCase turns a snake_case name into a class name', () {
    expect(pascalCase('home_screen'), 'HomeScreen');
    expect(pascalCase('checkout'), 'Checkout');
    expect(pascalCase('a_b_c'), 'ABC');
  });

  test('the patch stub follows the EjenixPatchView entry convention', () {
    final src = scaffoldPatch(name: 'home_screen', sdkPrefix: '../patch_sdk');
    expect(src, contains("import '../patch_sdk/flutter.dart';"));
    expect(src, contains("import '../patch_sdk/app.dart';"));
    expect(
      src,
      contains('HomeScreenState createState() => HomeScreenState();'),
    );
    expect(
      src,
      contains('Widget build(BuildContext context, HomeScreenState state)'),
    );
  });

  test('the host view wraps EjenixPatchView with the app id filled in', () {
    final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
    // Stateful so the boot future can be resolved once in a field rather than
    // restarted on every rebuild — see the caching test below.
    expect(src, contains('class HomeScreenView extends StatefulWidget'));
    expect(src, contains('return EjenixPatchView('));
    expect(src, contains("appId: 'com.acme',"));
    // Qualified: the field lives on the widget, the build lives in its State.
    expect(src, contains('trustedKeys: HomeScreenView._trustedKeys,'));
    expect(src, contains('cacheDir: boot.cacheDir,'));
    expect(src, contains('bundledFallback: boot.fallback,'));
    expect(src, contains("rootBundle.load('assets/home_screen.bundle')"));
  });

  test(
    'the host view states env explicitly rather than inheriting a default',
    () {
      // EjenixPatchView defaults env to 'production'. A scaffold that omitted it
      // produced a view polling production while the developer promoted to
      // staging — the patch never arrived, with no error on any surface. Worse
      // in the other direction: a screen silently live to real users.
      final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
      expect(
        src,
        contains("env: 'staging',"),
        reason: 'env must be written out, not left to the production default',
      );
    },
  );

  test('a failed boot falls back instead of spinning forever', () {
    // Found by scaffolding into a real Flutter app and rendering it: the
    // FutureBuilder only handled `!hasData`, so if _boot() failed the screen
    // sat on a CircularProgressIndicator permanently — and EjenixPatchView was
    // never built, so the fallbackBuilder the developer wired could not run.
    // A silent infinite spinner is the worst possible failure for a widget
    // whose entire promise is fail-soft.
    final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
    expect(
      src,
      contains('if (snapshot.hasError)'),
      reason: 'boot failure must reach the fallback',
    );
  });

  test('the boot future is bounded, so a hang cannot strand the screen', () {
    // hasError catches a *failed* boot; nothing catches one that never
    // completes. Verified by rendering the scaffolded widget with no
    // path_provider implementation: without the deadline the screen sat on a
    // spinner permanently, with it the fallback appears.
    final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
    expect(src, contains('.timeout('));
  });

  test('the boot future is resolved once, not on every rebuild', () {
    // `future: _boot()` inline in build() starts a fresh future on every
    // rebuild, re-reading the bundled asset and flashing the loading state
    // whenever a parent rebuilds.
    final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
    expect(src, contains('late final Future<_Boot> _bootOnce = _boot()'));
    expect(
      src,
      isNot(contains('future: _boot(),')),
      reason: 'the future must be cached, not rebuilt',
    );
  });

  test('the host view always wires a fallback', () {
    // Without fallbackBuilder a failed patch renders SizedBox.shrink() — an
    // invisible hole where the screen was, with no crash and no message.
    final src = scaffoldView(name: 'home_screen', appId: 'com.acme');
    expect(src, contains('fallbackBuilder:'));
  });

  group('the scaffold command', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('scaffold_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes the patch and the host, with the right SDK import', () async {
      final r = await runCli([
        'scaffold',
        'home_screen',
        '--app-id',
        'com.acme',
        '--dir',
        dir.path,
      ]);
      expect(r.code, 0, reason: r.err);

      final patch = File(p.join(dir.path, 'patches', 'home_screen.dart'));
      final view = File(p.join(dir.path, 'lib', 'home_screen_view.dart'));
      expect(patch.existsSync(), isTrue);
      expect(view.existsSync(), isTrue);
      // patches/ and patch_sdk/ are siblings, so the import climbs one level.
      expect(
        patch.readAsStringSync(),
        contains("import '../patch_sdk/flutter.dart';"),
      );
      expect(view.readAsStringSync(), contains("appId: 'com.acme',"));
    });

    test('refuses to overwrite without --force, then obeys --force', () async {
      final args = ['scaffold', 'home_screen', '--dir', dir.path];
      expect((await runCli(args)).code, 0);

      final second = await runCli(args);
      expect(second.code, 73); // EX_CANTCREAT
      expect(second.err, contains('already exists'));

      final forced = await runCli([...args, '--force']);
      expect(forced.code, 0, reason: forced.err);
    });

    test('rejects a non-snake_case name', () async {
      final r = await runCli(['scaffold', 'HomeScreen', '--dir', dir.path]);
      expect(r.code, 64);
      expect(r.err, contains('snake_case'));
    });

    test('leaves a placeholder app id when none is given', () async {
      await runCli(['scaffold', 'settings', '--dir', dir.path]);
      final view = File(p.join(dir.path, 'lib', 'settings_view.dart'));
      expect(view.readAsStringSync(), contains("appId: '<app-id>',"));
    });
  });
}
