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

void main() {
  group('static methods', () {
    test('a static method is called directly', () async {
      expect(
        await run(
          'class C { static int f(int x) => x * 2; } int main() => C.f(5);',
        ),
        10,
      );
    });

    test('static method with named args', () async {
      const src = '''
class C { static int f({int a = 1, int b = 2}) => a * 10 + b; }
int main() => C.f(b: 9);
''';
      expect(await run(src), 19);
    });

    test('a static method tear-off', () async {
      const src = '''
class C { static int neg(int x) => -x; }
int main() => [1, 2, 3].map(C.neg).fold(0, (a, b) => a + b);
''';
      expect(await run(src), -6);
    });
  });

  group('static fields', () {
    test('const static field', () async {
      expect(
        await run('class C { static const int k = 42; } int main() => C.k;'),
        42,
      );
    });

    test('final static field with a computed initializer', () async {
      expect(
        await run('class C { static final int k = 3 + 4; } int main() => C.k;'),
        7,
      );
    });

    test('mutable static field get/set and compound assignment', () async {
      const src = '''
class C { static int count = 0; }
int main() {
  C.count = 5;
  C.count += 3;
  return C.count;
}
''';
      expect(await run(src), 8);
    });

    test('a static field is shared across instances', () async {
      const src = '''
class C {
  static int total = 0;
  int v;
  C(this.v) { total += v; }
}
int main() {
  C(3);
  C(4);
  return C.total;
}
''';
      expect(await run(src), 7);
    });

    test('unqualified static field access inside the class', () async {
      const src = '''
class C {
  static int n = 1;
  static void inc() { n += 10; }
  static int read() => n;
}
int main() {
  C.inc();
  return C.read();
}
''';
      expect(await run(src), 11);
    });

    test('the initializer runs once', () async {
      const src = '''
class Counter {
  static int calls = 0;
  static int make() { calls = calls + 1; return 7; }
  static int value = make();
}
int main() => Counter.value + Counter.value + Counter.calls;
''';
      // value initialized once to 7; two reads = 14; calls == 1 => 15
      expect(await run(src), 15);
    });
  });

  group('operator overloading', () {
    test('binary +', () async {
      const src = '''
class V { int n; V(this.n); V operator +(V o) => V(n + o.n); }
int main() => (V(3) + V(4)).n;
''';
      expect(await run(src), 7);
    });

    test('index operator', () async {
      const src = '''
class Box { int v; Box(this.v); int operator [](int i) => v + i; }
int main() => Box(10)[5];
''';
      expect(await run(src), 15);
    });

    test('unary minus', () async {
      const src = '''
class V { int n; V(this.n); V operator -() => V(-n); }
int main() => (-V(7)).n;
''';
      expect(await run(src), -7);
    });

    test('== override with an identity fallback', () async {
      const src = '''
class P {
  int x;
  P(this.x);
  bool operator ==(Object o) => o is P && o.x == x;
  int get hashCode => x;
}
class Q { int x; Q(this.x); }
int main() {
  var a = Q(1);
  return (P(1) == P(1) ? 1 : 0) * 1000
      + (P(1) == P(2) ? 1 : 0) * 100
      + (a == a ? 1 : 0) * 10
      + (Q(1) == Q(1) ? 1 : 0);
}
''';
      // P(1)==P(1) true; P(1)==P(2) false; a==a true (identity); Q(1)==Q(1) false
      expect(await run(src), 1010);
    });
  });
}
