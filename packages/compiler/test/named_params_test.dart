// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> run(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).run();
}

void main() {
  group('optional positional parameters', () {
    test('default used when omitted', () async {
      expect(
        await run('int f(int a, [int b = 10]) => a + b; int main() => f(5);'),
        15,
      );
    });
    test('default overridden when provided', () async {
      expect(
        await run(
          'int f(int a, [int b = 10]) => a + b; int main() => f(5, 7);',
        ),
        12,
      );
    });
    test('no explicit default becomes null', () async {
      expect(await run('int f([int? x]) => x ?? 99; int main() => f();'), 99);
    });
  });

  group('named parameters', () {
    test('single named with default', () async {
      expect(
        await run(
          'int f({int a = 1, int b = 2}) => a + b; int main() => f(b: 40);',
        ),
        41,
      );
    });
    test('both named provided', () async {
      expect(
        await run(
          'int f({int a = 1, int b = 2}) => a * 10 + b; int main() => f(a: 5, b: 6);',
        ),
        56,
      );
    });
    test('named arguments passed out of order', () async {
      expect(
        await run('''
int g(int x, {int y = 0, int z = 0}) => x * 100 + y * 10 + z;
int main() => g(1, z: 3, y: 2);
'''),
        123,
      );
    });
    test('required named parameter', () async {
      expect(
        await run(
          'int f({required int a, int b = 3}) => a * 10 + b; int main() => f(a: 5);',
        ),
        53,
      );
    });
    test('string default', () async {
      expect(
        await run(
          'String greet({String name = "world"}) => "hi " + name; String main() => greet();',
        ),
        'hi world',
      );
    });
  });

  group('constructors (the widget case)', () {
    test(
      'named constructor parameters with field-formals and defaults',
      () async {
        const src = '''
class Box {
  final int w;
  final int h;
  final int pad;
  Box({this.w = 0, this.h = 0, this.pad = 4});
  int area() => w * h + pad;
}
int main() => Box(w: 3, h: 4).area();
''';
        expect(await run(src), 16);
      },
    );

    test('constructor with a mix of positional and named', () async {
      const src = '''
class Rect {
  final int x;
  final int y;
  final int scale;
  Rect(this.x, this.y, {this.scale = 1});
  int total() => (x + y) * scale;
}
int main() => Rect(2, 3, scale: 4).total();
''';
      expect(await run(src), 20);
    });

    test('super constructor with an omitted optional', () async {
      const src = '''
class A {
  final int x;
  A([this.x = 7]);
}
class B extends A {
  B() : super();
}
int main() => B().x;
''';
      expect(await run(src), 7);
    });
  });

  group('diagnostics', () {
    test('super formal parameters now compile', () async {
      final r = await Compiler().compileSource(
        'class A { int x; A(this.x); } '
        'class B extends A { B(super.x); } '
        'int main() => B(7).x;',
      );
      expect(r.hasErrors, isFalse);
    });
  });
}
