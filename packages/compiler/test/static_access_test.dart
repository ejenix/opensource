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
  group('static methods', () {
    test('int.parse and int.tryParse', () async {
      expect(await run('int main() => int.parse("42");'), 42);
      expect(await run('int main() => int.tryParse("9") ?? -1;'), 9);
      expect(await run('int main() => int.tryParse("nope") ?? -1;'), -1);
    });

    test('double.parse', () async {
      expect(await run('double main() => double.parse("3.5");'), 3.5);
    });
  });

  group('dart:math free functions', () {
    test('min and max', () async {
      expect(await run('import "dart:math"; int main() => max(3, 7);'), 7);
      expect(await run('import "dart:math"; int main() => min(3, 7);'), 3);
    });

    test('sqrt and pow', () async {
      expect(await run('import "dart:math"; num main() => sqrt(16);'), 4.0);
      expect(
        await run('import "dart:math"; num main() => pow(2, 10);'),
        1024.0,
      );
    });
  });

  group('host constructors', () {
    test('await Future.value composes', () async {
      expect(
        await runAsync(
          'Future<int> main() async => await Future.value(41) + 1;',
        ),
        42,
      );
    });
  });
}
