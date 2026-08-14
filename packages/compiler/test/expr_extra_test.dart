// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// Compiles [source] and runs `main` through the VM, failing on compile errors.
Future<Object?> run(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).run();
}

void main() {
  group('assignment as an expression (value is used)', () {
    test('local assignment yields the assigned value', () async {
      const src = '''
int main() {
  var x = 0;
  var y = (x = 5);
  return x + y;
}
''';
      expect(await run(src), 10);
    });

    test(
      'unqualified field assignment yields the value via arrow body',
      () async {
        const src = '''
class Cfg {
  int v = 0;
  int setTo(int n) => v = n;
}
int main() => Cfg().setTo(9);
''';
        expect(await run(src), 9);
      },
    );

    test('field assignment through a receiver yields the value', () async {
      const src = '''
class Cell {
  int v;
  Cell(this.v);
}
int main() {
  var c = Cell(1);
  return c.v = 42;
}
''';
      expect(await run(src), 42);
    });
  });

  group('double-typed increment and decrement', () {
    test('++ and -- step a double variable by one', () async {
      const src = '''
double main() {
  var x = 1.5;
  x++;
  x++;
  x--;
  return x;
}
''';
      expect(await run(src), 2.5);
    });
  });

  group('this as a first-class value', () {
    test('a method can return this', () async {
      const src = '''
class Box {
  int v;
  Box(this.v);
  Box identity() => this;
}
int main() {
  var b = Box(5);
  var c = b.identity();
  return c.v;
}
''';
      expect(await run(src), 5);
    });
  });

  group('bare boolean literals', () {
    test('a function returning a boolean literal', () async {
      const src = '''
bool yes() => true;
bool no() => false;
int main() => (yes() && !no()) ? 1 : 0;
''';
      expect(await run(src), 1);
    });
  });

  group('graceful diagnostics for out-of-subset constructs', () {
    Future<CompileResult> compile(String src) => Compiler().compileSource(src);

    test('instance-method named args now compile', () async {
      // Named args on unit-declared instance methods are now supported.
      final r = await compile('''
class C {
  int f({int a = 0}) => a;
}
int main() => C().f(a: 1);
''');
      expect(r.hasErrors, isFalse);
    });

    test('operator overloading now compiles', () async {
      final r = await compile('''
class C {
  int n;
  C(this.n);
  C operator +(C o) => C(n + o.n);
}
int main() => (C(1) + C(2)).n;
''');
      expect(r.hasErrors, isFalse);
    });

    test('a top-level variable is reported', () async {
      final r = await compile('int counter = 0; int main() => counter;');
      expect(r.hasErrors, isTrue);
    });

    test('try/catch now compiles without error', () async {
      final r = await compile(
        'int main() { try { return 1; } catch (e) { return 2; } }',
      );
      expect(r.hasErrors, isFalse);
    });

    test('a symbol literal now compiles', () async {
      final r = await compile('Symbol main() => #foo;');
      expect(r.hasErrors, isFalse);
    });

    test('a record literal now compiles without error', () async {
      final r = await compile('int main() { var r = (1, 2); return r.\$1; }');
      expect(r.hasErrors, isFalse);
    });

    test('a list pattern now compiles', () async {
      // List/map/object patterns and nested subpatterns are now supported.
      final r = await compile(
        'int main() { var [a, b] = [1, 2]; return a + b; }',
      );
      expect(r.hasErrors, isFalse);
    });
  });
}
