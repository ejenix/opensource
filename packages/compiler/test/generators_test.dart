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
  group('sync* generators', () {
    test('yields are iterable with a for-in loop', () async {
      const src = '''
Iterable<int> nums() sync* {
  yield 1;
  yield 2;
  yield 3;
}
int main() {
  var s = 0;
  for (var n in nums()) s += n;
  return s;
}
''';
      expect(await run(src), 6);
    });

    test('yield* delegates to another generator', () async {
      const src = '''
Iterable<int> a() sync* { yield 1; yield 2; }
Iterable<int> b() sync* { yield 0; yield* a(); yield 3; }
int main() => b().length;
''';
      expect(await run(src), 4);
    });

    test('a loop drives the yields', () async {
      const src = '''
Iterable<int> squares(int n) sync* {
  for (var i = 0; i < n; i++) yield i * i;
}
int main() {
  var s = 0;
  for (var x in squares(4)) s += x;
  return s;
}
''';
      expect(await run(src), 14);
    });

    test('the result works with higher-order methods', () async {
      const src = '''
Iterable<int> g() sync* { yield 1; yield 2; yield 3; }
int main() => g().map((x) => x * 10).fold(0, (a, b) => a + b);
''';
      expect(await run(src), 60);
    });
  });

  group('async* generators and await for', () {
    test('async* yields consumed by await for', () async {
      const src = '''
Stream<int> nums() async* {
  yield 10;
  yield 20;
}
Future<int> main() async {
  var s = 0;
  await for (var n in nums()) s += n;
  return s;
}
''';
      expect(await run(src), 30);
    });

    test('await for over an external stream', () async {
      const src = '''
Future<int> main() async {
  var s = 0;
  await for (var x in Stream.fromIterable([1, 2, 3, 4])) s += x;
  return s;
}
''';
      expect(await run(src), 10);
    });
  });

  group('lazy generators', () {
    test('an infinite generator is consumed lazily with take', () async {
      const src = '''
Iterable<int> nats() sync* {
  var i = 0;
  while (true) {
    yield i;
    i = i + 1;
  }
}
int main() => nats().take(5).fold(0, (a, b) => a + b);
''';
      expect(await run(src), 10);
    });

    test('firstWhere pulls only until the match', () async {
      const src = '''
Iterable<int> nats() sync* {
  var i = 0;
  while (true) {
    yield i;
    i++;
  }
}
int main() => nats().firstWhere((x) => x > 100);
''';
      expect(await run(src), 101);
    });

    test('a generator can be iterated more than once', () async {
      const src = '''
Iterable<int> g() sync* { yield 1; yield 2; }
int main() {
  var it = g();
  return it.length + it.length;
}
''';
      expect(await run(src), 4);
    });
  });

  group('generator limitations', () {
    test('await inside an async* generator now compiles', () async {
      final result = await Compiler().compileSource('''
Stream<int> g() async* {
  yield await Future.value(1);
}
''');
      expect(result.hasErrors, isFalse);
    });
  });
}
