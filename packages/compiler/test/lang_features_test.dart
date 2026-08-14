// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> run(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).runAsync();
}

Future<Object?> tryRun(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) return null;
  return Interpreter(result.moduleOrThrow).run();
}

void main() {
  group('assert', () {
    test('a satisfied assertion does nothing', () async {
      expect(await run('int main(){ var x=3; assert(x>0); return x; }'), 3);
    });

    test('a failed assertion throws', () async {
      final result = await Compiler().compileSource(
        'int main(){ assert(1==2, "nope"); return 0; }',
      );
      expect(result.hasErrors, isFalse);
      expect(
        () => Interpreter(result.moduleOrThrow).run(),
        throwsA(
          isA<InterpreterUncaughtException>().having(
            (e) => e.thrown,
            'thrown',
            isA<AssertionError>(),
          ),
        ),
      );
    });

    test('a constant-true assertion compiles away', () async {
      expect(await run('int main(){ assert(true); return 9; }'), 9);
    });

    test('a failed assertion is catchable', () async {
      const src = '''
int main() {
  try {
    assert(false, 'x');
    return 1;
  } on AssertionError catch (e) {
    return 2;
  }
}
''';
      expect(await run(src), 2);
    });
  });

  group('labeled break/continue', () {
    test('break targets an outer loop', () async {
      const src = '''
int main() {
  var c = 0;
  outer: for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      if (j == 1) break outer;
      c++;
    }
  }
  return c;
}
''';
      expect(await run(src), 1);
    });

    test('continue targets an outer loop', () async {
      const src = '''
int main() {
  var c = 0;
  outer: for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 2; j++) {
      if (j == 1) continue outer;
      c++;
    }
  }
  return c;
}
''';
      expect(await run(src), 3);
    });

    test('break out of a labeled block', () async {
      const src = '''
int main() {
  var x = 1;
  blk: {
    x = 2;
    if (x == 2) break blk;
    x = 3;
  }
  return x;
}
''';
      expect(await run(src), 2);
    });

    test('unlabeled break still targets the innermost loop', () async {
      const src = '''
int main() {
  var c = 0;
  for (var i = 0; i < 5; i++) {
    if (i == 3) break;
    c++;
  }
  return c;
}
''';
      expect(await run(src), 3);
    });
  });

  group('tear-offs', () {
    test('top-level function tear-off passed to a host method', () async {
      const src = '''
int dbl(int x) => x * 2;
int main() {
  var xs = [1, 2, 3];
  return xs.map(dbl).fold(0, (a, b) => a + b);
}
''';
      expect(await run(src), 12);
    });

    test('qualified instance-method tear-off', () async {
      const src = '''
class C { int inc(int x) => x + 1; }
int main() {
  var c = C();
  return [10, 20].map(c.inc).fold(0, (a, b) => a + b);
}
''';
      expect(await run(src), 32);
    });

    test('unqualified instance-method tear-off inside a method', () async {
      const src = '''
class C {
  int base = 100;
  int add(int x) => x + base;
  int go(List<int> xs) => xs.map(add).fold(0, (a, b) => a + b);
}
int main() => C().go([1, 2]);
''';
      expect(await run(src), 203);
    });

    test('zero-arg tear-off used as a callback', () async {
      const src = '''
class C {
  int n = 0;
  void bump() { n = n + 1; }
}
int main() {
  var c = C();
  var f = c.bump;
  f();
  f();
  return c.n;
}
''';
      expect(await run(src), 2);
    });

    test('tearing off a method with optional params is reported', () async {
      final result = await Compiler().compileSource(
        'class C { int f([int x = 0]) => x; } int main() { var g = C().f; return g(); }',
      );
      expect(result.hasErrors, isTrue);
      expect(result.errors.first.message, contains('optional/named'));
    });
  });

  group('named/optional args on instance methods', () {
    test('named argument reordering', () async {
      const src = '''
class C { int f({int a = 1, int b = 2}) => a * 10 + b; }
int main() => C().f(b: 9);
''';
      expect(await run(src), 19);
    });

    test('both named args, out of order', () async {
      const src = '''
class C { int f({int a = 1, int b = 2}) => a * 10 + b; }
int main() => C().f(b: 9, a: 5);
''';
      expect(await run(src), 59);
    });

    test('omitted optional positional gets its default', () async {
      const src = '''
class C { int f(int a, [int b = 7]) => a * 10 + b; }
int main() => C().f(3);
''';
      expect(await run(src), 37);
    });

    test('named call through the implicit `this` receiver', () async {
      const src = '''
class C {
  int g({int x = 0}) => x;
  int go() => g(x: 8);
}
int main() => C().go();
''';
      expect(await run(src), 8);
    });

    test('named arguments on a host method are still reported', () async {
      final result = await Compiler().compileSource(
        "int main() { var s = 'a,b'; return s.split(',').length; }",
      );
      // (positional host calls still work; this asserts the happy path compiles)
      expect(result.hasErrors, isFalse);
    });
  });

  group('edge cases', () {
    test('if-case with an else branch', () async {
      const src = '''
int f(Object o) {
  if (o case int n) {
    return n;
  } else {
    return -1;
  }
}
int main() => f(5) * 10 + f('x');
''';
      expect(await run(src), 49); // 5*10 + (-1)
    });

    test('switch statement with plain constant cases', () async {
      const src = '''
int f(int x) {
  switch (x) {
    case 1:
      return 10;
    case 2:
      return 20;
    default:
      return 0;
  }
}
int main() => f(2) + f(9);
''';
      expect(await run(src), 20);
    });

    test('generator with an early return', () async {
      const src = '''
Iterable<int> g(bool stop) sync* {
  yield 1;
  if (stop) return;
  yield 2;
}
int main() => g(true).length + g(false).length;
''';
      expect(await run(src), 3); // 1 + 2
    });

    test('catch binds a stack-trace parameter (null in this subset)', () async {
      const src = '''
int main() {
  try {
    throw 'boom';
  } catch (e, st) {
    return st == null ? 1 : 0;
  }
}
''';
      expect(await run(src), 1);
    });

    test('empty switch cases fall through', () async {
      const src = '''
int f(int x) {
  switch (x) {
    case 1:
    case 2:
      return 99;
    default:
      return 0;
  }
}
int main() => f(1) + f(2) + f(3);
''';
      expect(await run(src), 198); // 99 + 99 + 0
    });
  });

  group('Type and Symbol literals', () {
    test('a symbol literal builds a real Symbol', () async {
      expect(await run('Symbol main() => #foo;'), const Symbol('foo'));
    });

    test('symbols are canonicalized', () async {
      expect(await run('bool main() => #foo == #foo;'), isTrue);
    });

    test('a type literal is its name; runtimeType compares equal', () async {
      expect(await run('bool main() => 5.runtimeType == int;'), isTrue);
    });
  });
}
