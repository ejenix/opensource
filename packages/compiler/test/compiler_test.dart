// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// Compiles [source] and runs function [fn] with [args] through the VM.
Future<Object?> run(
  String source, {
  String fn = 'main',
  List<Object?> args = const [],
}) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected compile errors:\n${result.diagnostics.join('\n')}');
  }
  final module = result.moduleOrThrow;
  final proto = module.functions.firstWhere((f) => f.name == fn);
  return Interpreter(module).callFunction(proto, args);
}

void main() {
  group('expressions', () {
    test('integer arithmetic', () async {
      expect(
        await run('int f(int a, int b) => a + b * 2;', fn: 'f', args: [3, 4]),
        11,
      );
      expect(await run('int f(int a) => -a;', fn: 'f', args: [5]), -5);
      expect(
        await run('int f(int a, int b) => a % b;', fn: 'f', args: [17, 5]),
        2,
      );
      expect(
        await run('int f(int a, int b) => a ~/ b;', fn: 'f', args: [17, 5]),
        3,
      );
    });

    test('double arithmetic', () async {
      expect(
        await run(
          'double f(double a, double b) => a * b;',
          fn: 'f',
          args: [1.5, 2.0],
        ),
        3.0,
      );
      expect(
        await run('double f(double a) => -a;', fn: 'f', args: [3.5]),
        -3.5,
      );
    });

    test('/ always yields a double', () async {
      final r = await run('double f(int n) => n / 2;', fn: 'f', args: [5]);
      expect(r, 2.5);
      expect(r, isA<double>());
    });

    test('mixed int/double arithmetic widens the int', () async {
      final r = await run(
        'double f(int a, double b) => a + b;',
        fn: 'f',
        args: [3, 0.5],
      );
      expect(r, 3.5);
    });

    test('comparisons and equality', () async {
      expect(
        await run('bool f(int a, int b) => a < b;', fn: 'f', args: [1, 2]),
        isTrue,
      );
      expect(
        await run('bool f(int a, int b) => a >= b;', fn: 'f', args: [1, 2]),
        isFalse,
      );
      expect(
        await run('bool f(int a, int b) => a == b;', fn: 'f', args: [2, 2]),
        isTrue,
      );
      expect(
        await run(
          'bool f(double a, double b) => a > b;',
          fn: 'f',
          args: [3.0, 2.0],
        ),
        isTrue,
      );
    });

    test('short-circuit logical operators', () async {
      const src = 'bool f(int x) => x > 0 && x < 10;';
      expect(await run(src, fn: 'f', args: [5]), isTrue);
      expect(await run(src, fn: 'f', args: [-1]), isFalse);
      expect(await run(src, fn: 'f', args: [20]), isFalse);
      const orSrc = 'bool f(int x) => x < 0 || x > 10;';
      expect(await run(orSrc, fn: 'f', args: [5]), isFalse);
      expect(await run(orSrc, fn: 'f', args: [20]), isTrue);
    });

    test('ternary conditional', () async {
      const src = 'int f(int x) => x < 0 ? 0 : (x > 10 ? 10 : x);';
      expect(await run(src, fn: 'f', args: [-5]), 0);
      expect(await run(src, fn: 'f', args: [5]), 5);
      expect(await run(src, fn: 'f', args: [50]), 10);
    });

    test('boolean not and null/bool/string literals', () async {
      expect(
        await run('bool f(bool b) => !b;', fn: 'f', args: [true]),
        isFalse,
      );
      expect(await run("String f() => 'hi';", fn: 'f'), 'hi');
      expect(await run('Object? f() => null;', fn: 'f'), isNull);
    });
  });

  group('statements and control flow', () {
    test('recursive fibonacci', () async {
      const src = '''
int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
''';
      expect(await run(src, fn: 'fib', args: [10]), 55);
      expect(await run(src, fn: 'fib', args: [20]), 6765);
    });

    test('for loop with i++ and compound assignment', () async {
      const src = '''
int fact(int n) {
  var acc = 1;
  for (var i = 1; i <= n; i++) {
    acc *= i;
  }
  return acc;
}
''';
      expect(await run(src, fn: 'fact', args: [0]), 1);
      expect(await run(src, fn: 'fact', args: [5]), 120);
    });

    test('while loop with local mutation', () async {
      const src = '''
int sumTo(int n) {
  var total = 0;
  var i = 1;
  while (i <= n) {
    total += i;
    i++;
  }
  return total;
}
''';
      expect(await run(src, fn: 'sumTo', args: [5]), 15);
      expect(await run(src, fn: 'sumTo', args: [100]), 5050);
    });

    test('break and continue', () async {
      const src = '''
int firstMultiple(int n, int limit) {
  var result = -1;
  for (var i = 1; i < limit; i++) {
    if (i % n != 0) continue;
    result = i;
    break;
  }
  return result;
}
''';
      expect(await run(src, fn: 'firstMultiple', args: [7, 100]), 7);
      expect(await run(src, fn: 'firstMultiple', args: [9, 5]), -1);
    });

    test('prefix decrement and nested blocks', () async {
      const src = '''
int countdown(int n) {
  var steps = 0;
  while (n > 0) {
    --n;
    {
      steps = steps + 1;
    }
  }
  return steps;
}
''';
      expect(await run(src, fn: 'countdown', args: [4]), 4);
    });

    test('runs the main entry point', () async {
      final result = await Compiler().compileSource('int main() => 6 * 7;');
      expect(Interpreter(result.moduleOrThrow).run(), 42);
    });
  });

  group('determinism', () {
    test('same source compiles to byte-identical bytecode', () async {
      const src = '''
int fib(int n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
''';
      final a = (await Compiler().compileSource(src)).moduleOrThrow;
      final b = (await Compiler().compileSource(src)).moduleOrThrow;
      expect(a.functions.length, b.functions.length);
      for (var i = 0; i < a.functions.length; i++) {
        expect(a.functions[i].code, b.functions[i].code);
        expect(a.functions[i].registerCount, b.functions[i].registerCount);
      }
      expect(a.constants.values, b.constants.values);
    });
  });

  group('diagnostics', () {
    test(
      'reports an unsupported top-level declaration with a location',
      () async {
        final result = await Compiler().compileSource('int topLevel = 0;');
        expect(result.hasErrors, isTrue);
        expect(result.module, isNull);
        final d = result.errors.first;
        expect(d.message, contains('not yet supported'));
        expect(d.line, 1);
        expect(d.toString(), contains('error'));
      },
    );

    test('surfaces analyzer errors for invalid source', () async {
      final result = await Compiler().compileSource('int f() { return ; }');
      expect(result.hasErrors, isTrue);
    });

    test('reports an unsupported expression inside a function', () async {
      // An unsupported compound assignment is still out of subset.
      final result = await Compiler().compileSource(
        'int f(int a, int b) { a &= b; return a; }',
      );
      expect(result.hasErrors, isTrue);
      expect(
        result.errors.first.correction ?? result.errors.first.message,
        isNotEmpty,
      );
    });

    test('moduleOrThrow throws on failure', () async {
      final result = await Compiler().compileSource('int topLevel = 0;');
      expect(() => result.moduleOrThrow, throwsA(isA<CompileException>()));
    });
  });
}
