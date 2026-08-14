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
  group('capture', () {
    test('a closure reads a captured local', () async {
      const src = '''
int main() {
  var base = 10;
  int add(int x) => x + base;
  return add(5);
}
''';
      expect(await run(src), 15);
    });

    test('a closure mutates a captured local (counter)', () async {
      const src = '''
int main() {
  var n = 0;
  void bump() { n = n + 1; }
  bump();
  bump();
  bump();
  return n;
}
''';
      expect(await run(src), 3);
    });

    test(
      'captured local survives after the enclosing scope via return',
      () async {
        const src = '''
int Function() makeCounter() {
  var count = 0;
  return () {
    count = count + 1;
    return count;
  };
}
int main() {
  var c = makeCounter();
  c();
  c();
  return c();
}
''';
        expect(await run(src), 3);
      },
    );

    test('two closures share one captured cell', () async {
      const src = '''
int main() {
  var total = 0;
  void addTwo() { total = total + 2; }
  int read() => total;
  addTwo();
  addTwo();
  return read();
}
''';
      expect(await run(src), 4);
    });

    test('a closure stored in a variable is invoked', () async {
      const src = '''
int main() {
  final f = (int x) => x * x;
  return f(6);
}
''';
      expect(await run(src), 36);
    });

    test('compound assignment through a captured variable', () async {
      const src = '''
int main() {
  var acc = 1;
  void scale(int k) { acc *= k; }
  scale(3);
  scale(4);
  return acc;
}
''';
      expect(await run(src), 12);
    });

    test('postfix increment on a captured variable', () async {
      const src = '''
int main() {
  var i = 0;
  int next() => i++;
  next();
  next();
  return next();
}
''';
      // returns the value *before* the third increment: 0,1,2 -> last returns 2.
      expect(await run(src), 2);
    });
  });

  group('higher-order collection methods', () {
    test('map with a capturing closure', () async {
      const src = '''
int main() {
  var factor = 10;
  var xs = [1, 2, 3];
  var ys = xs.map((e) => e * factor).toList();
  return ys[0] + ys[1] + ys[2];
}
''';
      expect(await run(src), 60);
    });

    test('where filters with a closure', () async {
      const src = '''
int main() {
  var xs = [1, 2, 3, 4, 5, 6];
  var evens = xs.where((e) => e % 2 == 0).toList();
  return evens.length;
}
''';
      expect(await run(src), 3);
    });

    test('fold sums with a closure', () async {
      const src = '''
int main() {
  var xs = [1, 2, 3, 4];
  return xs.fold(0, (acc, e) => acc + e);
}
''';
      expect(await run(src), 10);
    });

    test('forEach accumulates into a captured variable', () async {
      const src = '''
int main() {
  var sum = 0;
  var xs = [5, 10, 15];
  xs.forEach((e) { sum = sum + e; });
  return sum;
}
''';
      expect(await run(src), 30);
    });

    test('any and every with closures', () async {
      const src = '''
int main() {
  var xs = [2, 4, 6];
  var allEven = xs.every((e) => e % 2 == 0);
  var anyOdd = xs.any((e) => e % 2 == 1);
  return (allEven && !anyOdd) ? 1 : 0;
}
''';
      expect(await run(src), 1);
    });

    test('sort with a comparator closure', () async {
      const src = '''
int main() {
  var xs = [3, 1, 2];
  xs.sort((a, b) => a - b);
  return xs[0] * 100 + xs[1] * 10 + xs[2];
}
''';
      expect(await run(src), 123);
    });
  });

  group('capturing this', () {
    test('a closure captures this explicitly', () async {
      expect(
        await run('''
class C {
  int factor = 2;
  int Function(int) scaler() => (int x) => x * this.factor;
}
int main() => C().scaler()(5);
'''),
        10,
      );
    });

    test('a closure captures an instance field (implicit this)', () async {
      expect(
        await run('''
class C {
  int factor = 2;
  int Function(int) scaler() => (int x) => x * factor;
}
int main() => C().scaler()(5);
'''),
        10,
      );
    });

    test('a nested closure mutating a field (setState pattern)', () async {
      expect(
        await run('''
class C {
  int n = 0;
  void Function() handler() => () {
    var apply = () { n = n + 1; };
    apply();
    apply();
  };
}
int main() {
  var c = C();
  c.handler()();
  return c.n;
}
'''),
        2,
      );
    });
  });
}
