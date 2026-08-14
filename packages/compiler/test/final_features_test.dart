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
  group('explicit super.member', () {
    test('super method call', () async {
      const src = '''
class A { int f() => 10; }
class B extends A { int f() => super.f() + 5; }
int main() => B().f();
''';
      expect(await run(src), 15);
    });

    test('super field read', () async {
      const src = '''
class A { int x = 7; }
class B extends A { int g() => super.x + 1; }
int main() => B().g();
''';
      expect(await run(src), 8);
    });

    test('super getter', () async {
      const src = '''
class A { int get v => 100; }
class B extends A { int get v => super.v * 2; }
int main() => B().v;
''';
      expect(await run(src), 200);
    });
  });

  group('redirecting factory', () {
    test('forwards to the target constructor', () async {
      const src = '''
abstract class Shape {
  int area();
  factory Shape(int a) = Square;
}
class Square implements Shape {
  int a;
  Square(this.a);
  int area() => a;
}
int main() => Shape(9).area();
''';
      expect(await run(src), 9);
    });

    test('redirects to a constructor that is itself a factory', () async {
      const src = '''
class A {
  final int v;
  A._(this.v);
  factory A() = A.two;
  factory A.two() => A._(2);
}
int main() => A().v;
''';
      expect(await run(src), 2);
    });
  });

  group('constructor delegation with named args', () {
    test('named arguments forwarded to super', () async {
      const src = '''
class A {
  final int x;
  final int y;
  A({this.x = 0, this.y = 0});
}
class B extends A {
  B() : super(y: 5, x: 3);
  int sum() => x + y;
}
int main() => B().sum();
''';
      expect(await run(src), 8);
    });

    test('named arguments in a this(...) redirect', () async {
      const src = '''
class P {
  final int a;
  final int b;
  P({this.a = 0, this.b = 0});
  P.only() : this(b: 7);
  int sum() => a + b;
}
int main() => P.only().sum();
''';
      expect(await run(src), 7);
    });
  });

  group('extension types', () {
    test('construction and representation are identity', () async {
      expect(
        await run(
          'extension type Meters(int value) {} int main() => Meters(42).value;',
        ),
        42,
      );
    });

    test('members dispatch on the representation', () async {
      const src = '''
extension type Celsius(double value) {
  double toF() => value * 9 / 5 + 32;
}
int main() => Celsius(100.0).toF().toInt();
''';
      expect(await run(src), 212);
    });
  });

  group('async* with await', () {
    test('a generator both yields and awaits', () async {
      const src = '''
Future<int> fetch(int x) async => x * 10;
Stream<int> g() async* {
  for (var i = 1; i <= 3; i++) {
    yield await fetch(i);
  }
}
Future<int> main() async {
  var s = 0;
  await for (var v in g()) s += v;
  return s;
}
''';
      expect(await run(src), 60);
    });
  });

  _closureQualifiedFieldTests();

  group('sandbox boundary', () {
    test('dart:ffi is rejected with a suggestion', () async {
      final r = await Compiler().compileSource(
        "import 'dart:ffi'; void f() {}",
      );
      expect(r.hasErrors, isTrue);
      final d = r.errors.first;
      expect(d.code, 'E0200');
      expect(d.message, contains('sandbox'));
      expect(d.correction, isNotNull);
    });

    test('dart:math is allowed', () async {
      final r = await Compiler().compileSource(
        "import 'dart:math'; int main() => 0;",
      );
      expect(r.hasErrors, isFalse);
    });
  });
}

// Regression: a closure that mutates *another object's* field was misread as
// capturing `this` (the qualified receiver was ignored), so the single most
// common stateful-callback shape failed to compile.
void _closureQualifiedFieldTests() {
  group('closure over a qualified field (not a this-capture)', () {
    test('a top-level closure mutates a field through a receiver', () async {
      const src = '''
class Counter { int count = 0; }
int main() {
  var c = Counter();
  var bump = () { c.count = c.count + 1; };
  bump();
  bump();
  return c.count;
}
''';
      expect(await run(src), 2);
    });

    test(
      'a doubly-nested closure mutates a field through a receiver',
      () async {
        const src = '''
class Counter { int count = 0; }
int run(void Function() f) { f(); return 0; }
int main() {
  var c = Counter();
  var outer = () { run(() { c.count = c.count + 5; }); };
  outer();
  return c.count;
}
''';
        expect(await run(src), 5);
      },
    );

    test('an unqualified instance member still captures this', () async {
      const src = '''
class Box {
  int v = 1;
  int bump() {
    var f = () { v = v + 10; };
    f();
    return v;
  }
}
int main() => Box().bump();
''';
      expect(await run(src), 11);
    });
  });
}
