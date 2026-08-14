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
  group('named/optional args on host methods', () {
    test('optional positional argument', () async {
      expect(await run("String main() => 'ab'.padLeft(4, '*');"), '**ab');
    });

    test('firstWhere with a named orElse (match)', () async {
      expect(await run('int main() => [1, 2, 3].firstWhere((x) => x > 1);'), 2);
    });

    test('firstWhere with a named orElse (no match)', () async {
      expect(
        await run(
          'int main() => [1, 2, 3].firstWhere((x) => x > 9, orElse: () => -1);',
        ),
        -1,
      );
    });

    test('positional host calls are unaffected', () async {
      expect(await run("int main() => 'a,b,c'.split(',').length;"), 3);
    });
  });
}
