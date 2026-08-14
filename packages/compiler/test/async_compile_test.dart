// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> runAsync(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).runAsync();
}

void main() {
  group('async / await', () {
    test('an async function returns its value', () async {
      expect(await runAsync('Future<int> main() async => 42;'), 42);
    });

    test('awaiting another async function composes', () async {
      const src = '''
Future<int> twenty() async => 20;
Future<int> total() async {
  var t = await twenty();
  return t + 22;
}
Future<int> main() async => await total();
''';
      expect(await runAsync(src), 42);
    });

    test('await inside a loop resumes correctly each iteration', () async {
      const src = '''
Future<int> one() async => 1;
Future<int> sumN(int n) async {
  var s = 0;
  for (var i = 0; i < n; i++) {
    s = s + await one();
  }
  return s;
}
Future<int> main() async => await sumN(5);
''';
      expect(await runAsync(src), 5);
    });

    test('await in a conditional expression', () async {
      const src = '''
Future<int> one() async => 1;
Future<int> pick(bool b) async => b ? await one() : 0;
Future<int> main() async => await pick(true) + await pick(false);
''';
      expect(await runAsync(src), 1);
    });

    test('an async closure is awaited', () async {
      const src = '''
Future<int> main() async {
  final f = () async => 7;
  return await f();
}
''';
      expect(await runAsync(src), 7);
    });

    test('an async method on a class', () async {
      const src = '''
class Counter {
  int base;
  Counter(this.base);
  Future<int> next() async => base + 1;
}
Future<int> main() async => await Counter(41).next();
''';
      expect(await runAsync(src), 42);
    });
  });

  group('diagnostics', () {
    Future<CompileResult> compile(String src) => Compiler().compileSource(src);

    test('async* (Stream) generators now compile', () async {
      final r = await compile('Stream<int> f() async* { yield 1; }');
      expect(r.hasErrors, isFalse);
    });

    test('sync* (Iterable) generators now compile', () async {
      final r = await compile('Iterable<int> f() sync* { yield 1; }');
      expect(r.hasErrors, isFalse);
    });

    test('await for (Stream) loops now compile', () async {
      final r = await compile('''
Future<void> f(Stream<int> s) async {
  await for (final x in s) {
    print(x);
  }
}
''');
      expect(r.hasErrors, isFalse);
    });

    test('await inside an async* generator now compiles', () async {
      final r = await compile(
        'Stream<int> f() async* { yield await g(); }'
        ' Future<int> g() async => 1;',
      );
      expect(r.hasErrors, isFalse);
    });
  });
}
