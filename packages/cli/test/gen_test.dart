// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:ejenix_cli/cli.dart';
import 'package:ejenix_cli/src/codegen/capability_gen.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A self-contained fixture: it declares its own `Widget`, `Patchable`, and a
/// mini design-system + repository, so the generator can be exercised without
/// the Flutter SDK. The generator matches `@Patchable` by name and classifies
/// widgets by their supertype chain, so a local `Widget` is enough.
const _preamble = '''
class Widget {}
class StatelessWidget extends Widget {}

class Patchable {
  const Patchable([this.name]);
  final String? name;
}
const patchable = Patchable();
''';

Future<GeneratedCapabilities> gen(
  String body, {
  String importPath = 'fixture.dart',
}) async {
  final dir = Directory.systemTemp.createTempSync('gen_test');
  final file = File(p.join(dir.path, 'fixture.dart'))
    ..writeAsStringSync('$_preamble\n$body');
  final collection = AnalysisContextCollection(
    includedPaths: [file.absolute.path],
  );
  try {
    final resolved = await collection
        .contextFor(file.absolute.path)
        .currentSession
        .getResolvedUnit(file.absolute.path);
    return CapabilityGenerator().generate([
      CapabilitySource(
        unit: resolved as ResolvedUnitResult,
        importPath: importPath,
      ),
    ]);
  } finally {
    await collection.dispose();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  // Four bugs found by integrating against a real design system. Each one
  // produced code that compiled-and-misbehaved or failed only at `flutter
  // test` time, so each gets a test that pins the generated expression.
  group('argument marshalling', () {
    test(
      'an omitted optional binds the declared default, not the type zero',
      () async {
        // The original bug: `enabled = true` generated `?? false`, so a patch
        // that omitted `enabled:` got a permanently disabled button — silently,
        // and exactly backwards.
        final out = await gen('''
@patchable
class Btn extends StatelessWidget {
  Btn({this.enabled = true, this.count = 4, this.title = 'hi'});
  final bool enabled;
  final int count;
  final String title;
}
''');
        expect(out.capabilities, contains("m['enabled'] as bool? ?? true"));
        expect(out.capabilities, contains("m['count'] as int? ?? 4"));
        expect(out.capabilities, contains("m['title'] as String? ?? 'hi'"));
        expect(out.capabilities, isNot(contains('as bool? ?? false')));
      },
    );

    test(
      'a parameter with no declared default still gets the type zero',
      () async {
        final out = await gen('''
@patchable
class Btn extends StatelessWidget {
  Btn({required this.label, required this.on});
  final String label;
  final bool on;
}
''');
        expect(out.capabilities, contains("m['label'] as String? ?? ''"));
        expect(out.capabilities, contains("m['on'] as bool? ?? false"));
      },
    );

    test(
      'a required non-nullable Widget gets a real fallback, not a bare cast',
      () async {
        // `Widget` has no zero value, so this used to emit `m['child'] as Widget?`
        // straight into a non-nullable slot: "The argument type 'Widget?' can't be
        // assigned to the parameter type 'Widget'".
        final out = await gen('''
@patchable
class Card extends StatelessWidget {
  Card({required this.child});
  final Widget child;
}
''');
        expect(
          out.capabilities,
          contains("m['child'] as Widget? ?? const SizedBox.shrink()"),
        );
      },
    );

    test('a nullable Widget stays a plain nullable cast', () async {
      final out = await gen('''
@patchable
class Card extends StatelessWidget {
  Card({this.child});
  final Widget? child;
}
''');
      expect(out.capabilities, contains("m['child'] as Widget?"));
      expect(out.capabilities, isNot(contains('SizedBox.shrink')));
    });
  });

  group('generated code compiles everywhere', () {
    test(
      'a Widget capability imports the library that defines Widget',
      () async {
        // Without this the generated file says "'Widget' isn't a type" — and
        // because most projects exclude `**/*.g.dart` from analysis, `flutter
        // analyze` passes and `flutter test` is where it blows up.
        final out = await gen('''
@patchable
class Card extends StatelessWidget {
  Card({this.child});
  final Widget? child;
}
''');
        expect(
          out.capabilities,
          contains("import 'package:flutter/widgets.dart';"),
        );
      },
    );

    test('no Widget anywhere means no Flutter import', () async {
      final out = await gen('''
@patchable
int answer() => 42;
''');
      expect(
        out.capabilities,
        isNot(contains("import 'package:flutter/widgets.dart';")),
      );
    });

    test('ignored closure params do not need Dart 3.7 wildcards', () async {
      // `(_, _)` requires language version >= 3.7; below that the CFE rejects it
      // with "'_' is already declared in this scope". `(_, __)` is valid in
      // every version.
      final out = await gen('''
@patchable
int answer() => 42;
''');
      expect(out.capabilities, contains('(_, __)'));
      expect(out.capabilities, isNot(contains('(_, _)')));
    });
  });

  test('generates the SDK + capabilities for the canonical shapes', () async {
    final out = await gen('''
@patchable
class PrimaryButton extends StatelessWidget {
  PrimaryButton({required this.label, this.onPressed});
  final String label;
  final void Function()? onPressed;
}

class TodoRepository {
  @Patchable('App.pendingCount')
  int get pendingCount => 0;

  @Patchable('App.addTodo')
  void addTodo(String title) {}

  @Patchable('App.toggleTodo')
  void toggleTodo(int id) {}
}

@Patchable('greet')
String greet(String name) => 'hi \$name';
''');

    // --- SDK: a patch's view -------------------------------------------------
    expect(out.sdk, contains('class PrimaryButton implements Widget {'));
    expect(
      out.sdk,
      contains(
        'external PrimaryButton({required String label, '
        'void Function()? onPressed});',
      ),
    );
    expect(out.sdk, contains('class App {'));
    expect(out.sdk, contains('external static int get pendingCount;'));
    expect(out.sdk, contains('external static void addTodo(String title);'));
    expect(out.sdk, contains('external String greet(String name);'));

    // --- Capabilities: the host bindings ------------------------------------
    // The instance-backed members drive a repository parameter.
    expect(
      out.capabilities,
      contains('HostExtension appCapabilities(TodoRepository todoRepository)'),
    );
    expect(
      out.capabilities,
      contains("registerGlobal('PrimaryButton', (_, a) {"),
    );
    expect(out.capabilities, contains("label: m['label'] as String? ?? '',"));
    expect(
      out.capabilities,
      contains("onPressed: ctx.callback(m['onPressed'])"),
    );
    // A getter needs no args; a void method returns null.
    expect(
      out.capabilities,
      contains(
        "registerGlobal('App.pendingCount', (_, __) => "
        'todoRepository.pendingCount)',
      ),
    );
    expect(
      out.capabilities,
      contains(
        "todoRepository.addTodo(m['title'] as String? ?? ''); "
        'return null;',
      ),
    );
    // A top-level function is called directly, no receiver.
    expect(
      out.capabilities,
      contains("return greet(m['name'] as String? ?? '');"),
    );
    expect(
      out.capabilities,
      contains("import 'package:ejenix_flutter/ejenix_flutter.dart';"),
    );
    expect(out.capabilities, contains("import 'fixture.dart';"));
  });

  test('narrows Widget-typed params and marshals 1-arg callbacks', () async {
    final out = await gen('''
@patchable
class Panel extends StatelessWidget {
  Panel({required this.title, this.child, this.onChanged});
  final String title;
  final Widget? child;
  final void Function(String)? onChanged;
}
''');
    // A concrete Widget subtype surfaces to a patch as plain `Widget`.
    expect(out.sdk, contains('Widget? child'));
    expect(out.sdk, contains('void Function(String)? onChanged'));
    expect(out.capabilities, contains("child: m['child'] as Widget?"));
    expect(
      out.capabilities,
      contains("onChanged: ctx.callbackWith<String>(m['onChanged'])"),
    );
  });

  test('output is deterministic', () async {
    const src = '''
@Patchable('App.count')
int count() => 0;
''';
    final a = await gen(src);
    final b = await gen(src);
    expect(a.sdk, b.sdk);
    expect(a.capabilities, b.capabilities);
  });

  test('rejects a parameter type that cannot cross the sandbox', () async {
    expect(
      () => gen('''
@Patchable('App.save')
void save(DateTime when) {}
'''),
      throwsA(
        isA<CapabilityGenException>().having(
          (e) => e.message,
          'message',
          contains('does not marshal'),
        ),
      ),
    );
  });

  test('rejects a multi-argument callback with a fixable message', () async {
    expect(
      () => gen('''
@patchable
class Grid extends StatelessWidget {
  Grid({this.builder});
  final Widget Function(int, int)? builder;
}
'''),
      throwsA(
        isA<CapabilityGenException>().having(
          (e) => e.message,
          'message',
          contains('0- or 1-argument callbacks'),
        ),
      ),
    );
  });

  test('errors when nothing is annotated', () async {
    expect(() => gen('class Plain {}'), throwsA(isA<CapabilityGenException>()));
  });

  test('rebuild: awaits a Future, then requests a view rebuild', () async {
    final out = await gen('''
class Repo {
  @Patchable('App.refresh', true)
  Future<void> refresh() async {}

  @Patchable('App.bump', true)
  void bump() {}
}
''');
    // A Future is awaited before the rebuild; a sync mutator is not.
    expect(
      out.capabilities,
      contains(
        "registerGlobal('App.refresh', (_, __) async { await repo.refresh(); "
        'ctx.requestRebuild?.call(); return null; })',
      ),
    );
    expect(
      out.capabilities,
      contains(
        "registerGlobal('App.bump', (_, __) { repo.bump(); "
        'ctx.requestRebuild?.call(); return null; })',
      ),
    );
  });

  test('generated imports are ordered package-before-relative', () async {
    final out = await gen('''
@Patchable('App.x')
int x() => 0;
''', importPath: 'src/app.dart');
    final pkg = out.capabilities.indexOf("import 'package:ejenix_flutter");
    final rel = out.capabilities.indexOf("import 'src/app.dart';");
    expect(pkg, greaterThanOrEqualTo(0));
    expect(pkg, lessThan(rel));
  });

  test('the `ejenix gen` command writes both files', () async {
    final dir = Directory.systemTemp.createTempSync('gen_cmd');
    try {
      final src = File(p.join(dir.path, 'caps.dart'))
        ..writeAsStringSync(
          "$_preamble\n@Patchable('App.count')\nint count() => 0;",
        );
      final sdkOut = p.join(dir.path, 'patch_sdk', 'app.dart');
      final capsOut = p.join(dir.path, 'lib', 'app_capabilities.g.dart');

      final out = StringBuffer();
      final err = StringBuffer();
      final code =
          await EjenixRunner(out: out, err: err, isOutputTerminal: false).run([
            'gen',
            src.path,
            '--out-sdk',
            sdkOut,
            '--out-capabilities',
            capsOut,
          ]);

      expect(code, 0, reason: err.toString());
      expect(
        File(sdkOut).readAsStringSync(),
        contains('external static int count();'),
      );
      expect(
        File(capsOut).readAsStringSync(),
        contains("registerGlobal('App.count'"),
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
