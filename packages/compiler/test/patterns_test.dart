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
  group('destructuring declarations', () {
    test('list pattern', () async {
      expect(
        await run(
          'int main(){ var [a, b, c] = [1, 2, 3]; return a*100+b*10+c; }',
        ),
        123,
      );
    });

    test('list pattern with a rest element', () async {
      expect(
        await run(
          'int main(){ var [first, ...rest] = [10, 20, 30, 40]; return first + rest.length; }',
        ),
        13,
      );
    });

    test('nested record/list pattern', () async {
      expect(
        await run(
          'int main(){ var (a, [b, c]) = (1, [2, 3]); return a*100+b*10+c; }',
        ),
        123,
      );
    });
  });

  group('switch expressions with patterns', () {
    test('record patterns bind fields', () async {
      const src = '''
int f((int, int) p) => switch (p) {
  (0, var y) => y,
  (var x, 0) => x,
  _ => -1,
};
int main() => f((0, 7));
''';
      expect(await run(src), 7);
    });

    test('guards', () async {
      const src = '''
String f(int n) => switch (n) {
  var x when x < 0 => 'neg',
  0 => 'zero',
  _ => 'pos',
};
String main() => f(-5);
''';
      expect(await run(src), 'neg');
    });

    test('relational and logical-and patterns', () async {
      const src = '''
String f(int n) => switch (n) {
  < 0 => 'neg',
  >= 0 && <= 9 => 'digit',
  _ => 'big',
};
String main() => f(5);
''';
      expect(await run(src), 'digit');
    });

    test('logical-or of constants', () async {
      const src = '''
bool weekend(int d) => switch (d) {
  6 || 7 => true,
  _ => false,
};
int main() => weekend(6) ? 1 : 0;
''';
      expect(await run(src), 1);
    });
  });

  group('object patterns', () {
    test('bind getters, matching by field', () async {
      const src = '''
class P { int x; int y; P(this.x, this.y); }
int f(P p) => switch (p) {
  P(x: 0, y: var b) => b,
  P(x: var a, y: 0) => a,
  _ => -1,
};
int main() => f(P(0, 9));
''';
      expect(await run(src), 9);
    });
  });

  group('switch statements with patterns', () {
    test('binds a variable used in the body', () async {
      const src = '''
int f((int, String) r) {
  switch (r) {
    case (var n, _):
      return n;
  }
}
int main() => f((42, 'x'));
''';
      expect(await run(src), 42);
    });
  });

  group('if-case', () {
    test('binds in the then-branch with a guard', () async {
      const src = '''
int f(Object o) {
  if (o case int n when n > 5) return n * 2;
  return 0;
}
int main() => f(10);
''';
      expect(await run(src), 20);
    });

    test('the else-branch runs on mismatch', () async {
      const src = '''
int f(Object o) {
  if (o case String s) return s.length;
  return -1;
}
int main() => f(42);
''';
      expect(await run(src), -1);
    });
  });

  group('map patterns', () {
    test('require a key and bind its value', () async {
      const src = '''
int f(Map<String, int> m) {
  if (m case {'a': var v}) return v;
  return -1;
}
int main() => f({'a': 8, 'b': 9});
''';
      expect(await run(src), 8);
    });
  });
}
