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
  group('generics (type-erased)', () {
    test('generic class with a type parameter field', () async {
      const src = '''
class Box<T> {
  T value;
  Box(this.value);
  T get() => value;
}
int main() => Box<int>(5).get();
''';
      expect(await run(src), 5);
    });

    test('generic function with explicit type argument', () async {
      const src = '''
T first<T>(List<T> xs) => xs[0];
int main() => first<int>([3, 4]);
''';
      expect(await run(src), 3);
    });

    test('generic function with inferred type', () async {
      expect(await run('T id<T>(T x) => x; int main() => id(42);'), 42);
    });

    test('generic class with two parameters', () async {
      const src = '''
class Pair<A, B> {
  A a;
  B b;
  Pair(this.a, this.b);
}
int main() {
  var p = Pair<int, String>(7, 'x');
  return p.a;
}
''';
      expect(await run(src), 7);
    });

    test('bounded type parameter', () async {
      const src = '''
num total<T extends num>(List<T> xs) {
  num s = 0;
  for (var x in xs) s = s + x;
  return s;
}
int main() => total<int>([1, 2, 3]).toInt();
''';
      expect(await run(src), 6);
    });
  });

  group('mixins', () {
    test('a class gains a mixin method', () async {
      const src = '''
mixin M { int foo() => 10; }
class C with M {}
int main() => C().foo();
''';
      expect(await run(src), 10);
    });

    test('a mixin field is folded into the class', () async {
      const src = '''
mixin Counter {
  int count = 0;
  void inc() { count = count + 1; }
}
class C with Counter {}
int main() {
  var c = C();
  c.inc();
  c.inc();
  return c.count;
}
''';
      expect(await run(src), 2);
    });

    test('the class overrides a mixin method', () async {
      const src = '''
mixin M { int v() => 1; }
class C with M { int v() => 2; }
int main() => C().v();
''';
      expect(await run(src), 2);
    });

    test('a mixin method calls an abstract hook the class supplies', () async {
      const src = '''
mixin Greet {
  String greet() => name();
  String name();
}
class C with Greet {
  String name() => 'hi';
}
String main() => C().greet();
''';
      expect(await run(src), 'hi');
    });

    test('extends and with together', () async {
      const src = '''
class A { int base() => 100; }
mixin M { int extra() => 5; }
class C extends A with M {}
int main() => C().base() + C().extra();
''';
      expect(await run(src), 105);
    });

    test('two mixins linearize left to right', () async {
      const src = '''
mixin M1 { int a() => 1; }
mixin M2 { int b() => 2; }
class C with M1, M2 {}
int main() => C().a() * 10 + C().b();
''';
      expect(await run(src), 12);
    });
  });

  group('extension methods', () {
    test('method on a core type', () async {
      const src = '''
extension E on int { int twice() => this * 2; }
int main() => 5.twice();
''';
      expect(await run(src), 10);
    });

    test('getter on a core type', () async {
      const src = '''
extension E on int { int get squared => this * this; }
int main() => 6.squared;
''';
      expect(await run(src), 36);
    });

    test('method with an argument', () async {
      const src = '''
extension E on int { int plus(int x) => this + x; }
int main() => 10.plus(7);
''';
      expect(await run(src), 17);
    });

    test('unqualified member access dispatches on the receiver', () async {
      const src = '''
extension E on String { int get charCount => length; }
int main() => 'hello'.charCount;
''';
      expect(await run(src), 5);
    });

    test('extension on a user class', () async {
      const src = '''
class P { int x = 3; }
extension E on P { int doubled() => x * 2; }
int main() => P().doubled();
''';
      expect(await run(src), 6);
    });
  });
}
