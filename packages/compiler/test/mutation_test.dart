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
  group('do / while', () {
    test('runs the body at least once', () async {
      expect(
        await run('int main(){ var i=0; do { i=i+1; } while(i<3); return i; }'),
        3,
      );
    });
    test('runs exactly once when the condition is already false', () async {
      expect(
        await run('int main(){ var i=9; do { i=i+1; } while(i<3); return i; }'),
        10,
      );
    });
    test('break and continue work in a do/while', () async {
      const src = '''
int main() {
  var i = 0;
  var sum = 0;
  do {
    i = i + 1;
    if (i == 2) continue;
    if (i == 5) break;
    sum = sum + i;
  } while (i < 100);
  return sum;
}
''';
      // adds 1 + 3 + 4 = 8 (skips 2, stops at 5)
      expect(await run(src), 8);
    });
  });

  group('compound assignment to fields', () {
    test('+= and *= on a field', () async {
      const src = '''
class C { int v = 0; }
int main() { var c = C(); c.v += 5; c.v *= 2; return c.v; }
''';
      expect(await run(src), 10);
    });
    test('??= on a nullable field', () async {
      const src = '''
class C { int? v; }
int main() { var c = C(); c.v ??= 7; c.v ??= 9; return c.v ?? 0; }
''';
      expect(await run(src), 7);
    });
  });

  group('compound assignment to indexed targets', () {
    test('+= and -= on list elements', () async {
      const src = '''
int main() { var xs = [10, 20]; xs[0] += 5; xs[1] -= 3; return xs[0] * 100 + xs[1]; }
''';
      expect(await run(src), 1517);
    });
    test('??= on a list element', () async {
      const src = '''
int main() {
  var xs = <int?>[null, 2];
  xs[0] ??= 5;
  return (xs[0] ?? 0) * 10 + (xs[1] ?? 0);
}
''';
      expect(await run(src), 52);
    });
  });

  group('collection spread, if, and for elements', () {
    test('list spread including the middle', () async {
      expect(
        await run(
          'int main(){ var a=[2,3]; var b=[1,...a,4]; return b[0]*1000+b[1]*100+b[2]*10+b[3]; }',
        ),
        1234,
      );
    });
    test('null-aware spread of a null source', () async {
      expect(
        await run(
          'int main(){ List<int>? a; var b=[1,...?a,2]; return b.length; }',
        ),
        2,
      );
    });
    test('collection-if with else', () async {
      expect(
        await run(
          'int main(){ var b=false; var l=[if(b) 1 else 2]; return l[0]; }',
        ),
        2,
      );
    });
    test('collection-for (C-style)', () async {
      expect(
        await run(
          'int main(){ var l=[for (var i=0;i<3;i++) i*10]; return l[0]+l[1]+l[2]; }',
        ),
        30,
      );
    });
    test('collection-for-in with a nested if', () async {
      expect(
        await run('''
int main() {
  var xs = [1, 2, 3, 4];
  var evens = [for (var x in xs) if (x % 2 == 0) x];
  return evens.length;
}
'''),
        2,
      );
    });
    test('set and map spread', () async {
      expect(
        await run(
          'int main(){ var a={1,2}; var b={...a,3}; return b.length; }',
        ),
        3,
      );
      expect(
        await run(
          'int main(){ var a={"x":1}; var b={...a,"y":2}; return b.length; }',
        ),
        2,
      );
    });
  });

  group('cascades', () {
    test('method cascades on a list', () async {
      expect(
        await run(
          'int main(){ var l = <int>[]..add(1)..add(2)..add(3); return l.length; }',
        ),
        3,
      );
    });
    test('field-assignment cascades', () async {
      const src = '''
class P { int x = 0; int y = 0; }
int main() { var p = P()..x = 3..y = 4; return p.x * 10 + p.y; }
''';
      expect(await run(src), 34);
    });
    test('mixed method and field cascades', () async {
      const src = '''
class B { int n = 0; void bump() { n = n + 1; } }
int main() { var b = B()..bump()..bump()..n = 10; return b.n; }
''';
      expect(await run(src), 10);
    });
  });
}
