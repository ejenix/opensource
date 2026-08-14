// Copyright (c) Ejenix authors. MIT license.

import 'dart:async';

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
  group('strings', () {
    test('methods', () async {
      expect(await run("String f() => 'hello'.toUpperCase();"), 'HELLO');
      expect(await run("int f() => 'hello'.length;"), 5);
      expect(
        await run('String f(String s) => s.substring(1, 3);', args: ['abcd']),
        'bc',
      );
      expect(
        await run("bool f(String s) => s.contains('ell');", args: ['hello']),
        isTrue,
      );
      expect(
        await run(
          "String f(String s) => s.replaceAll('a', 'X');",
          args: ['banana'],
        ),
        'bXnXnX',
      );
    });

    test('concatenation, interpolation, adjacent strings', () async {
      expect(await run("String f() => 'a' + 'b' + 'c';"), 'abc');
      expect(
        await run("String f(int n) => 'count: \$n';", args: [7]),
        'count: 7',
      );
      expect(
        await run("String f(String w) => 'hi ' 'there ' '\$w';", args: ['bob']),
        'hi there bob',
      );
      expect(
        await run(
          "String f(int a, int b) => '\$a+\$b=\${a + b}';",
          args: [2, 3],
        ),
        '2+3=5',
      );
    });

    test('method chaining', () async {
      expect(
        await run("int f() => 'Hello World'.toLowerCase().split(' ').length;"),
        2,
      );
    });
  });

  group('collections', () {
    test('list literals, indexing, and methods', () async {
      expect(await run('int f() { var xs = [10, 20, 30]; return xs[1]; }'), 20);
      expect(await run('int f() { var xs = [1, 2, 3]; return xs.length; }'), 3);
      expect(
        await run(
          'int f() { var xs = <int>[]; xs.add(5); xs.add(6); return xs[0] + xs[1]; }',
        ),
        11,
      );
      expect(
        await run('int f() { var xs = [1, 2, 3]; xs[0] = 9; return xs[0]; }'),
        9,
      );
      expect(await run("String f() => [3, 1, 2].join('-');"), '3-1-2');
    });

    test('map literals and indexing', () async {
      expect(
        await run("int f() { var m = {'a': 1, 'b': 2}; return m['b']!; }"),
        2,
      );
      expect(
        await run(
          "bool f() { var m = <String, int>{}; m['x'] = 9; return m.containsKey('x'); }",
        ),
        isTrue,
      );
      expect(await run("int f() { var m = {'a': 1}; return m.length; }"), 1);
    });

    test('set literals', () async {
      expect(
        await run('bool f() { var s = {1, 2, 3}; return s.contains(2); }'),
        isTrue,
      );
      expect(
        await run(
          'int f() { var s = <int>{}; s.add(1); s.add(1); return s.length; }',
        ),
        1,
      );
    });

    test('for-in loop', () async {
      const src = '''
int f(List<int> xs) {
  var total = 0;
  for (var x in xs) {
    total += x;
  }
  return total;
}
''';
      expect(
        await run(
          src,
          args: [
            [1, 2, 3, 4],
          ],
        ),
        10,
      );
    });
  });

  group('null-aware operators', () {
    test('?? and ??=', () async {
      expect(await run('int f(int? a, int b) => a ?? b;', args: [null, 5]), 5);
      expect(await run('int f(int? a, int b) => a ?? b;', args: [3, 5]), 3);
      expect(
        await run('int f(int? a) { a ??= 7; return a; }', args: [null]),
        7,
      );
      expect(await run('int f(int? a) { a ??= 7; return a; }', args: [4]), 4);
    });

    test('?. and !', () async {
      expect(
        await run('int f(String? s) => s?.length ?? -1;', args: [null]),
        -1,
      );
      expect(
        await run('int f(String? s) => s?.length ?? -1;', args: ['abc']),
        3,
      );
      expect(await run('int f(int? a) => a!;', args: [9]), 9);
    });
  });

  group('operators via dispatch', () {
    test('bitwise and shifts', () async {
      expect(await run('int f() => 5 & 3;'), 1);
      expect(await run('int f() => 5 | 2;'), 7);
      expect(await run('int f() => 5 ^ 1;'), 4);
      expect(await run('int f() => 1 << 4;'), 16);
      expect(await run('int f() => 32 >> 2;'), 8);
      expect(await run('int f() => ~0;'), -1);
    });

    test('num-typed arithmetic dispatches', () async {
      expect(await run('num f(num a, num b) => a + b;', args: [2, 3]), 5);
      expect(await run('num f(num a, num b) => a * b;', args: [2, 2.5]), 5.0);
      expect(await run('bool f(num a, num b) => a < b;', args: [1, 2]), isTrue);
    });
  });

  group('globals', () {
    test('print is captured', () async {
      final result = await Compiler().compileSource(
        "void f() { print('hi'); }",
      );
      expect(result.hasErrors, isFalse, reason: result.diagnostics.join('\n'));
      final module = result.moduleOrThrow;
      final printed = <Object?>[];
      runZoned(
        () =>
            Interpreter(module).callFunction(module.functions.first, const []),
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => printed.add(line),
        ),
      );
      expect(printed, ['hi']);
    });
  });
}
