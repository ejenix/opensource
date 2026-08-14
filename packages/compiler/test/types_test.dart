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
  group('is / as', () {
    test('is on core types', () async {
      expect(
        await run('int main(){ Object o = 5; return o is int ? 1 : 0; }'),
        1,
      );
      expect(
        await run('int main(){ Object o = "x"; return o is int ? 1 : 0; }'),
        0,
      );
      expect(
        await run('int main(){ Object o = [1]; return o is List ? 1 : 0; }'),
        1,
      );
    });

    test('is! negation', () async {
      expect(
        await run('int main(){ Object o = 5; return o is! String ? 1 : 0; }'),
        1,
      );
    });

    test('is on user classes and superclasses', () async {
      const src = '''
class A {}
class B extends A {}
int main() {
  A a = B();
  return (a is B ? 1 : 0) + (a is A ? 10 : 0);
}
''';
      expect(await run(src), 11);
    });

    test('nullable type test', () async {
      expect(await run('int main(){ int? x; return x is int? ? 1 : 0; }'), 1);
    });

    test('as succeeds and returns the value', () async {
      expect(await run('int main(){ Object o = 42; return o as int; }'), 42);
    });

    test('as throws on a bad cast', () async {
      final result = await Compiler().compileSource(
        'int main(){ Object o = "x"; return o as int; }',
      );
      expect(
        () => Interpreter(result.moduleOrThrow).run(),
        throwsA(isA<InterpreterException>()),
      );
    });
  });

  group('switch statement', () {
    const src = '''
int classify(int n) {
  switch (n) {
    case 0:
      return 100;
    case 1:
    case 2:
      return 200;
    default:
      return 0;
  }
}
int main() => classify(0) + classify(1) + classify(2) + classify(9);
''';
    test('cases, fall-through, and default', () async {
      // 100 + 200 + 200 + 0
      expect(await run(src), 500);
    });

    test('switch on strings with break', () async {
      const s = '''
int main() {
  var r = 0;
  switch ("b") {
    case "a": r = 1; break;
    case "b": r = 2; break;
    default: r = 9;
  }
  return r;
}
''';
      expect(await run(s), 2);
    });
  });

  group('switch expression', () {
    test('constant arms and wildcard', () async {
      const src = '''
String name(int x) => switch (x) {
  1 => "one",
  2 => "two",
  _ => "many",
};
String main() => name(2);
''';
      expect(await run(src), 'two');
    });
  });

  group('enums', () {
    test('index, name, and toString', () async {
      expect(
        await run(
          'enum Color { red, green, blue } int main() => Color.green.index;',
        ),
        1,
      );
      expect(
        await run(
          'enum Color { red, green, blue } String main() => Color.blue.name;',
        ),
        'blue',
      );
      expect(
        await run(
          'enum Color { red, green } String main() => Color.red.toString();',
        ),
        'Color.red',
      );
    });

    test('equality and switch', () async {
      const src = '''
enum Dir { north, south, east, west }
int turn(Dir d) {
  switch (d) {
    case Dir.north: return 0;
    case Dir.east: return 90;
    case Dir.south: return 180;
    default: return 270;
  }
}
int main() => turn(Dir.south) + (Dir.north == Dir.north ? 1 : 0);
''';
      expect(await run(src), 181);
    });

    test('values list', () async {
      expect(await run('enum E { a, b, c } int main() => E.values.length;'), 3);
      expect(
        await run('enum E { a, b, c } String main() => E.values[2].name;'),
        'c',
      );
    });
  });
}
