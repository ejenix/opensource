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
  group('named constructors', () {
    test('a named constructor with a field formal', () async {
      expect(
        await run('class C { int x; C.at(this.x); } int main() => C.at(9).x;'),
        9,
      );
    });

    test('named and unnamed coexist', () async {
      const src = '''
class C {
  int x;
  C(this.x);
  C.zero() : x = 0;
}
int main() => C(5).x + C.zero().x;
''';
      expect(await run(src), 5);
    });

    test('a named constructor still runs field initializers', () async {
      const src = '''
class C {
  int x = 100;
  int y;
  C.make(this.y);
}
int main() {
  var c = C.make(5);
  return c.x + c.y;
}
''';
      expect(await run(src), 105);
    });
  });

  group('factory constructors', () {
    test('a factory returns a constructed instance', () async {
      const src = '''
class C { int x; C(this.x); factory C.zero() => C(0); }
int main() => C.zero().x;
''';
      expect(await run(src), 0);
    });

    test('a factory with branching logic', () async {
      const src = '''
class C {
  int x;
  C(this.x);
  factory C.of(int n) => n < 0 ? C(0) : C(n);
}
int main() => C.of(-5).x + C.of(7).x;
''';
      expect(await run(src), 7);
    });
  });

  group('redirecting constructors', () {
    test('this() redirect', () async {
      const src = '''
class C { int x; C(this.x); C.zero() : this(0); }
int main() => C.zero().x;
''';
      expect(await run(src), 0);
    });

    test('redirect with arguments', () async {
      const src = '''
class C {
  int a;
  int b;
  C(this.a, this.b);
  C.square(int n) : this(n, n);
}
int main() {
  var c = C.square(6);
  return c.a * c.b;
}
''';
      expect(await run(src), 36);
    });
  });

  group('super formal parameters', () {
    test('super.x forwards to the superclass constructor', () async {
      const src = '''
class A { int x; A(this.x); }
class B extends A { B(super.x); }
int main() => B(8).x;
''';
      expect(await run(src), 8);
    });

    test('super.x with an added subclass field', () async {
      const src = '''
class A { int x; A(this.x); }
class B extends A {
  int y;
  B(super.x, this.y);
}
int main() {
  var b = B(3, 4);
  return b.x * 10 + b.y;
}
''';
      expect(await run(src), 34);
    });
  });
}
