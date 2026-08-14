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
  group('record literals and field access', () {
    test(r'positional fields via $1 / $2', () async {
      const src = '''
int main() {
  var r = (10, 20);
  return r.\$1 * 100 + r.\$2;
}
''';
      expect(await run(src), 1020);
    });

    test('named fields', () async {
      const src = '''
int main() {
  var p = (x: 3, y: 4);
  return p.x * 10 + p.y;
}
''';
      expect(await run(src), 34);
    });

    test('mixed positional and named fields', () async {
      const src = '''
int main() {
  var r = (1, 2, tag: 3);
  return r.\$1 * 100 + r.\$2 * 10 + r.tag;
}
''';
      expect(await run(src), 123);
    });

    test('a record returned from a function', () async {
      const src = '''
(int, int) minMax(List<int> xs) {
  var lo = xs[0];
  var hi = xs[0];
  for (var x in xs) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  return (lo, hi);
}

int main() {
  var r = minMax([3, 1, 4, 1, 5, 9, 2]);
  return r.\$1 * 100 + r.\$2;
}
''';
      expect(await run(src), 109);
    });

    test('records nest', () async {
      const src = '''
int main() {
  var r = ((1, 2), 3);
  var inner = r.\$1;
  return inner.\$1 * 100 + inner.\$2 * 10 + r.\$2;
}
''';
      expect(await run(src), 123);
    });
  });

  group('record destructuring', () {
    test('positional destructuring in a var declaration', () async {
      const src = '''
int main() {
  var (a, b) = (7, 8);
  return a * 10 + b;
}
''';
      expect(await run(src), 78);
    });

    test('final destructuring', () async {
      const src = '''
int main() {
  final (a, b, c) = (1, 2, 3);
  return a * 100 + b * 10 + c;
}
''';
      expect(await run(src), 123);
    });

    test('named-field destructuring', () async {
      const src = '''
int main() {
  var (x: a, y: b) = (x: 5, y: 6);
  return a * 10 + b;
}
''';
      expect(await run(src), 56);
    });

    test('destructuring a record from a call', () async {
      const src = '''
(int, int) swap(int a, int b) => (b, a);

int main() {
  var (x, y) = swap(1, 2);
  return x * 10 + y;
}
''';
      expect(await run(src), 21);
    });
  });

  group('record equality and toString', () {
    test('structural equality', () async {
      const src = '''
int main() {
  var a = (1, 2);
  var b = (1, 2);
  var c = (1, 3);
  return (a == b ? 1 : 0) * 10 + (a == c ? 1 : 0);
}
''';
      expect(await run(src), 10);
    });

    test('toString renders fields', () async {
      const src = '''
String main() {
  var r = (1, 2);
  return r.toString();
}
''';
      expect(await run(src), '(1, 2)');
    });
  });
}
