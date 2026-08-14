// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:test/test.dart';

/// Compiles [source] and returns its first error message, failing if there is
/// none.
Future<String> firstError(String source) async {
  final result = await Compiler().compileSource(source);
  expect(result.hasErrors, isTrue, reason: 'expected a compile error');
  expect(result.module, isNull);
  return result.errors.first.message;
}

void main() {
  group('unsupported declarations', () {
    // Most declarations now compile (classes, mixins, enums, extensions,
    // extension types, typedefs, generics, all constructor forms). A top-level
    // variable is the remaining top-level gap.
    test('top-level variable', () async {
      expect(await firstError('int x = 0;'), contains('not yet supported'));
    });
  });

  group('sandbox-forbidden imports', () {
    // Native, reflective, and isolate libraries are permanently forbidden — the
    // sandbox boundary — and reported with a distinct code and a suggestion.
    test('dart:ffi', () async {
      final r = await Compiler().compileSource(
        "import 'dart:ffi'; void f() {}",
      );
      expect(r.hasErrors, isTrue);
      final d = r.errors.first;
      expect(d.code, 'E0200');
      expect(d.message, contains('not permitted in the sandbox'));
      expect(d.correction, contains('host'));
    });

    test('dart:io', () async {
      // Allowed to compile until now, which put the failure in the wrong place:
      // the host registers no File/Socket/Process capability, so such a patch
      // always failed — but on a user's device, as a fallback and a rollback,
      // rather than at build time where every other unreachable thing fails.
      final r = await Compiler().compileSource("import 'dart:io'; void f() {}");
      expect(r.hasErrors, isTrue);
      expect(r.errors.first.code, 'E0200');
    });

    test('dart:convert and dart:math stay allowed', () async {
      // The guard against over-correcting: patches legitimately parse JSON and
      // do arithmetic, and forbidding those would break real screens.
      for (final lib in const ['dart:convert', 'dart:math', 'dart:async']) {
        final r = await Compiler().compileSource("import '$lib'; void f() {}");
        expect(r.hasErrors, isFalse, reason: '$lib must remain importable');
      }
    });

    test('dart:mirrors', () async {
      expect(
        await firstError("import 'dart:mirrors'; void f() {}"),
        contains('not permitted in the sandbox'),
      );
    });

    test('dart:isolate', () async {
      expect(
        await firstError("import 'dart:isolate'; void f() {}"),
        contains('not permitted in the sandbox'),
      );
    });
  });

  group('unsupported expressions', () {
    test('unsupported compound assignment', () async {
      expect(
        await firstError('int f(int a, int b) { a &= b; return a; }'),
        contains('compound assignment'),
      );
    });

    test('increment of a dynamic variable', () async {
      expect(
        await firstError('int f() { dynamic x = 1; x++; return x; }'),
        contains('int or double'),
      );
    });
  });

  group('diagnostic formatting', () {
    test('warning diagnostics render distinctly', () {
      const d = CompileDiagnostic(
        severity: DiagnosticSeverity.warning,
        message: 'heads up',
        path: 'a.dart',
        line: 2,
        column: 3,
      );
      expect(d.isError, isFalse);
      expect(d.toString(), contains('warning'));
      expect(d.toString(), 'a.dart:2:3: warning: heads up');
    });

    test('error with code and correction', () {
      const d = CompileDiagnostic(
        severity: DiagnosticSeverity.error,
        message: 'nope',
        path: 'a.dart',
        line: 1,
        column: 1,
        code: 'E0100',
        correction: 'do it differently',
      );
      expect(d.toString(), contains('[E0100]'));
      expect(d.toString(), contains('correction: do it differently'));
    });
  });
}
