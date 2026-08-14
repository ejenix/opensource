// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> run(
  String source, {
  String fn = 'f',
  List<Object?> args = const [],
}) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors)
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  final module = result.moduleOrThrow;
  return Interpreter(
    module,
  ).callFunction(module.functions.firstWhere((f) => f.name == fn), args);
}

void main() {
  group('integer operator matrix', () {
    test('all binary operators', () async {
      expect(await run('int f(int a, int b) => a - b;', args: [10, 3]), 7);
      expect(await run('int f(int a, int b) => a * b;', args: [6, 7]), 42);
      expect(
        await run('bool f(int a, int b) => a <= b;', args: [2, 2]),
        isTrue,
      );
      expect(await run('bool f(int a, int b) => a > b;', args: [3, 2]), isTrue);
      expect(
        await run('bool f(int a, int b) => a >= b;', args: [3, 3]),
        isTrue,
      );
      expect(
        await run('bool f(int a, int b) => a != b;', args: [1, 2]),
        isTrue,
      );
    });

    test('compound assignments', () async {
      const src = '''
int f(int a) {
  a += 3;
  a -= 1;
  a *= 2;
  a %= 5;
  return a;
}
''';
      expect(await run(src, args: [4]), (((4 + 3) - 1) * 2) % 5);
    });

    test('postfix and prefix as values', () async {
      expect(
        await run(
          'int f(int a) { var b = a++; return b * 100 + a; }',
          args: [5],
        ),
        506,
      );
      expect(
        await run(
          'int f(int a) { var b = ++a; return b * 100 + a; }',
          args: [5],
        ),
        606,
      );
      expect(
        await run(
          'int f(int a) { var b = a--; return b * 100 + a; }',
          args: [5],
        ),
        504,
      );
    });
  });

  group('double operator matrix', () {
    test('all binary operators', () async {
      expect(
        await run('double f(double a, double b) => a - b;', args: [5.0, 1.5]),
        3.5,
      );
      expect(
        await run('double f(double a, double b) => a % b;', args: [5.5, 2.0]),
        1.5,
      );
      expect(
        await run('bool f(double a, double b) => a <= b;', args: [2.0, 2.0]),
        isTrue,
      );
      expect(
        await run('bool f(double a, double b) => a >= b;', args: [2.0, 3.0]),
        isFalse,
      );
      expect(
        await run('bool f(double a, double b) => a < b;', args: [1.0, 2.0]),
        isTrue,
      );
    });

    test('compound assignments including /=', () async {
      const src = '''
double f(double a) {
  a += 1.0;
  a -= 0.5;
  a *= 4.0;
  a /= 2.0;
  return a;
}
''';
      expect(await run(src, args: [1.0]), (((1.0 + 1.0) - 0.5) * 4.0) / 2.0);
    });

    test('mixed int/double comparison widens', () async {
      expect(
        await run('bool f(int a, double b) => a < b;', args: [3, 3.5]),
        isTrue,
      );
      expect(
        await run('bool f(double a, int b) => a >= b;', args: [3.5, 3]),
        isTrue,
      );
    });
  });

  group('literals and equality', () {
    test('string equality via generic eq/ne', () async {
      expect(await run("bool f() => 'a' == 'b';"), isFalse);
      expect(await run("bool f() => 'a' != 'b';"), isTrue);
    });

    test('large integer literal uses the constant pool', () async {
      expect(await run('int f() => 100000;'), 100000);
      expect(await run('int f() => -70000;'), -70000);
    });

    test('double and string constants', () async {
      expect(await run('double f() => 3.14;'), 3.14);
      expect(await run("String f() => 'hello world';"), 'hello world');
    });
  });

  group('control-flow forms', () {
    test('if/else statement', () async {
      const src = '''
int f(int x) {
  if (x > 0) {
    return 1;
  } else {
    return -1;
  }
}
''';
      expect(await run(src, args: [5]), 1);
      expect(await run(src, args: [-5]), -1);
    });

    test('for loop with expression (non-declaration) init', () async {
      const src = '''
int f(int n) {
  var s = 0;
  int i = 0;
  for (i = 1; i <= n; i++) {
    s += i;
  }
  return s;
}
''';
      expect(await run(src, args: [5]), 15);
    });

    test('functions calling each other', () async {
      const src = '''
int dbl(int x) => x * 2;
int inc(int x) => x + 1;
int f(int x) => dbl(inc(x));
''';
      expect(await run(src, args: [10]), 22);
    });
  });

  group('compileFile', () {
    test('compiles a file from disk', () async {
      final dir = Directory.systemTemp.createTempSync('ejenix_file_test');
      try {
        final file = File('${dir.path}/prog.dart')
          ..writeAsStringSync('int f(int a) => a * a;');
        final result = await Compiler().compileFile(file.path);
        expect(result.hasErrors, isFalse);
        final module = result.moduleOrThrow;
        final proto = module.functions.firstWhere((f) => f.name == 'f');
        expect(Interpreter(module).callFunction(proto, [9]), 81);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
