// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Object?> run(String source, {List<Object?> args = const []}) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return Interpreter(result.moduleOrThrow).run(args);
}

void main() {
  test('fields, constructor with field-formals, and a method', () async {
    const src = '''
class Point {
  int x, y;
  Point(this.x, this.y);
  int sum() => x + y;
}
int main() => Point(3, 4).sum();
''';
    expect(await run(src), 7);
  });

  test('field initializer and mutation via a method', () async {
    const src = '''
class Counter {
  int value = 0;
  void inc() {
    value = value + 1;
  }
  int get current => value;
}
int main() {
  var c = Counter();
  c.inc();
  c.inc();
  c.inc();
  return c.current;
}
''';
    expect(await run(src), 3);
  });

  test('getter computed from fields', () async {
    const src = '''
class Rect {
  int w, h;
  Rect(this.w, this.h);
  int get area => w * h;
}
int main() => Rect(3, 4).area;
''';
    expect(await run(src), 12);
  });

  test('constructor body assigning fields', () async {
    const src = '''
class Box {
  late int size;
  Box(int n) {
    size = n * 2;
  }
  int get s => size;
}
int main() => Box(5).s;
''';
    expect(await run(src), 10);
  });

  test('a method calls another method on this', () async {
    const src = '''
class Calc {
  int base;
  Calc(this.base);
  int doubled() => base * 2;
  int quad() => doubled() * 2;
}
int main() => Calc(5).quad();
''';
    expect(await run(src), 20);
  });

  test('field read and write through a receiver', () async {
    const src = '''
class Cell {
  int v;
  Cell(this.v);
}
int main() {
  var c = Cell(1);
  c.v = 42;
  return c.v;
}
''';
    expect(await run(src), 42);
  });

  test('inheritance with an overridden virtual method', () async {
    const src = '''
class Animal {
  String sound() => 'generic';
  String describe() => 'a ' + sound();
}
class Dog extends Animal {
  String sound() => 'woof';
}
String main() => Dog().describe();
''';
    // describe() is inherited from Animal but calls sound(), which resolves to
    // Dog's override via virtual dispatch.
    expect(await run(src), 'a woof');
  });

  test('subclass adds a field and inherits behavior', () async {
    const src = '''
class Base {
  int a;
  Base(this.a);
  int total() => a;
}
class Derived extends Base {
  int b;
  Derived(int a, this.b) : super(a);
  int total() => a + b;
}
int main() {
  var d = Derived(3, 4);
  return d.total();
}
''';
    expect(await run(src), 7);
  });

  test('objects stored in a collection', () async {
    const src = '''
class Item {
  int price;
  Item(this.price);
}
int main() {
  var items = [Item(10), Item(20), Item(30)];
  var total = 0;
  for (var it in items) {
    total += it.price;
  }
  return total;
}
''';
    expect(await run(src), 60);
  });

  group('host construction', () {
    test('an unregistered out-of-unit constructor faults at runtime', () async {
      // Out-of-unit construction routes to a host global, validated against the
      // allow-list at runtime — the same boundary as host method calls. An
      // unregistered type is not a compile error; it faults when executed.
      final result = await Compiler().compileSource(
        'int main() { DateTime.now(); return 1; }',
      );
      expect(result.hasErrors, isFalse);
      expect(
        () => Interpreter(result.moduleOrThrow).run(),
        throwsA(isA<InterpreterException>()),
      );
    });
  });
}
