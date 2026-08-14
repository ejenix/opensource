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

Future<Object?> runAsync(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).runAsync();
}

void main() {
  group('throw / catch', () {
    test('catch binds the thrown value', () async {
      const src = '''
int main() {
  try {
    throw 42;
  } catch (e) {
    return e as int;
  }
}
''';
      expect(await run(src), 42);
    });

    test('no throw runs the body and skips the catch', () async {
      const src = '''
int main() {
  var x = 1;
  try {
    x = 2;
  } catch (e) {
    x = 99;
  }
  return x;
}
''';
      expect(await run(src), 2);
    });

    test('throw of a computed value', () async {
      const src = '''
int main() {
  try {
    var a = 3;
    throw a * a;
  } catch (e) {
    return (e as int) + 1;
  }
}
''';
      expect(await run(src), 10);
    });

    test('catch without a parameter', () async {
      const src = '''
int main() {
  try {
    throw 1;
  } catch (_) {
    return 7;
  }
}
''';
      expect(await run(src), 7);
    });
  });

  group('typed catch clauses', () {
    test('on Exception catches an Exception', () async {
      const src = '''
int main() {
  try {
    throw FormatException('bad');
  } on FormatException catch (e) {
    return 5;
  }
}
''';
      expect(await run(src), 5);
    });

    test('first matching clause wins; others are skipped', () async {
      const src = '''
int main() {
  try {
    throw FormatException('x');
  } on StateError catch (e) {
    return 1;
  } on FormatException catch (e) {
    return 2;
  } catch (e) {
    return 3;
  }
}
''';
      expect(await run(src), 2);
    });

    test('falls through to the catch-all when no type matches', () async {
      const src = '''
int main() {
  try {
    throw 99;
  } on FormatException catch (e) {
    return 1;
  } catch (e) {
    return (e as int) + 1;
  }
}
''';
      expect(await run(src), 100);
    });

    test('a host exception from int.parse is catchable', () async {
      const src = '''
int main() {
  try {
    return int.parse('not a number');
  } on FormatException catch (e) {
    return -1;
  }
}
''';
      expect(await run(src), -1);
    });
  });

  group('finally', () {
    test('runs on normal completion', () async {
      const src = '''
int main() {
  var log = 0;
  try {
    log = log + 1;
  } finally {
    log = log + 10;
  }
  return log;
}
''';
      expect(await run(src), 11);
    });

    test('runs after a caught exception', () async {
      const src = '''
int main() {
  var log = 0;
  try {
    throw 1;
  } catch (e) {
    log = log + 1;
  } finally {
    log = log + 10;
  }
  return log;
}
''';
      expect(await run(src), 11);
    });

    test('runs before an uncaught exception propagates', () async {
      const src = '''
int main() {
  var log = <int>[];
  try {
    try {
      throw 1;
    } finally {
      log.add(7);
    }
  } catch (e) {
    log.add(9);
  }
  return log[0] * 10 + log[1];
}
''';
      // finally (7) runs before the outer catch (9) sees the re-raised throw.
      expect(await run(src), 79);
    });

    test('return inside try still runs finally', () async {
      const src = '''
int main() {
  var trace = [0, 0];
  var r = compute(trace);
  return r * 10 + trace[0];
}

int compute(List<int> trace) {
  try {
    return 3;
  } finally {
    trace[0] = 5;
  }
}
''';
      // returns 3, but finally set trace[0]=5 first: 3*10 + 5 = 35
      expect(await run(src), 35);
    });

    test('break inside try runs finally', () async {
      const src = '''
int main() {
  var sum = 0;
  for (var i = 0; i < 5; i++) {
    try {
      if (i == 2) break;
      sum = sum + i;
    } finally {
      sum = sum + 100;
    }
  }
  return sum;
}
''';
      // i=0: sum=0+0, +100 => 100
      // i=1: sum=100+1, +100 => 201
      // i=2: break, finally +100 => 301
      expect(await run(src), 301);
    });
  });

  group('rethrow', () {
    test('rethrow propagates to an outer catch', () async {
      const src = '''
int main() {
  try {
    try {
      throw 5;
    } catch (e) {
      rethrow;
    }
  } catch (e) {
    return (e as int) * 2;
  }
}
''';
      expect(await run(src), 10);
    });
  });

  group('async try/catch', () {
    test('catches a throw across an await', () async {
      const src = '''
Future<int> boom() async {
  await Future.value(0);
  throw 7;
}

Future<int> main() async {
  try {
    await boom();
    return 0;
  } catch (e) {
    return (e as int) + 1;
  }
}
''';
      expect(await runAsync(src), 8);
    });

    test('finally runs across an awaited failure', () async {
      const src = '''
Future<int> boom() async {
  await Future.value(0);
  throw 1;
}

Future<int> main() async {
  var log = <int>[];
  try {
    await boom();
  } catch (e) {
    log.add(2);
  } finally {
    log.add(3);
  }
  return log[0] * 10 + log[1];
}
''';
      expect(await runAsync(src), 23);
    });

    test('an uncaught async throw fails the future', () async {
      final result = await Compiler().compileSource('''
Future<int> main() async {
  await Future.value(0);
  throw 55;
}
''');
      expect(result.hasErrors, isFalse);
      final interp = Interpreter(result.moduleOrThrow);
      await expectLater(
        interp.runAsync(),
        throwsA(
          isA<InterpreterUncaughtException>().having(
            (e) => e.thrown,
            'thrown',
            55,
          ),
        ),
      );
    });
  });

  group('uncaught', () {
    test(
      'an uncaught throw surfaces as InterpreterUncaughtException',
      () async {
        final result = await Compiler().compileSource('''
int main() {
  throw 123;
}
''');
        expect(result.hasErrors, isFalse);
        final interp = Interpreter(result.moduleOrThrow);
        expect(
          () => interp.run(),
          throwsA(
            isA<InterpreterUncaughtException>().having(
              (e) => e.thrown,
              'thrown',
              123,
            ),
          ),
        );
      },
    );
  });
}
