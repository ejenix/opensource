// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// Builds `bool f(v) => v is <spec>` and runs it against [value].
bool isOf(String spec, Object? value) {
  final k = ConstantPool();
  final s = k.add(spec);
  final fn =
      (BytecodeBuilder()
            ..emitABx(Op.isType, 0, s)
            ..emitA(Op.ret, 0))
          .toProto(name: 'f', paramCount: 1, registerCount: 1);
  final module = Module(constants: k, functions: [fn]);
  return Interpreter(module).callFunction(fn, [value]) as bool;
}

/// Builds `f(v) => v as <spec>` and runs it against [value].
Object? asOf(String spec, Object? value) {
  final k = ConstantPool();
  final s = k.add(spec);
  final fn =
      (BytecodeBuilder()
            ..emitABx(Op.asType, 0, s)
            ..emitA(Op.ret, 0))
          .toProto(name: 'f', paramCount: 1, registerCount: 1);
  final module = Module(constants: k, functions: [fn]);
  return Interpreter(module).callFunction(fn, [value]);
}

void main() {
  group('is.type against core types', () {
    test('int / double / num', () {
      expect(isOf('int', 5), isTrue);
      expect(isOf('int', 5.0), isFalse);
      expect(isOf('double', 5.0), isTrue);
      expect(isOf('num', 5), isTrue);
      expect(isOf('num', 5.0), isTrue);
      expect(isOf('num', 'x'), isFalse);
    });

    test('String / bool', () {
      expect(isOf('String', 'x'), isTrue);
      expect(isOf('bool', true), isTrue);
      expect(isOf('bool', 1), isFalse);
    });

    test('List / Map / Set / Iterable', () {
      expect(isOf('List', <int>[1]), isTrue);
      expect(isOf('Map', <int, int>{}), isTrue);
      expect(isOf('Set', <int>{1}), isTrue);
      expect(isOf('Iterable', <int>[1]), isTrue);
      expect(isOf('List', 5), isFalse);
    });

    test('Object / dynamic / Null', () {
      expect(isOf('Object', 5), isTrue);
      expect(isOf('dynamic', 'x'), isTrue);
      expect(isOf('Object', null), isFalse);
      expect(isOf('Null', null), isTrue);
      expect(isOf('Null', 5), isFalse);
    });

    test('nullable specs', () {
      expect(isOf('int?', null), isTrue);
      expect(isOf('int?', 5), isTrue);
      expect(isOf('int?', 'x'), isFalse);
    });

    test('Function matches closures and function protos', () {
      final proto = (BytecodeBuilder()..emitA(Op.ret, 0)).toProto(
        name: 'g',
        paramCount: 1,
        registerCount: 1,
      );
      expect(isOf('Function', proto), isTrue);
      expect(isOf('Function', InterpClosure(proto, const [])), isTrue);
      expect(isOf('Function', 5), isFalse);
    });
  });

  group('is.type against the exception hierarchy', () {
    test('Exception and its subtypes', () {
      expect(isOf('Exception', const FormatException('x')), isTrue);
      expect(isOf('FormatException', const FormatException('x')), isTrue);
      expect(isOf('Exception', 5), isFalse);
      expect(isOf('FormatException', StateError('x')), isFalse);
    });

    test('Error and its subtypes', () {
      expect(isOf('Error', StateError('x')), isTrue);
      expect(isOf('StateError', StateError('x')), isTrue);
      expect(isOf('ArgumentError', ArgumentError('x')), isTrue);
      expect(isOf('RangeError', RangeError('x')), isTrue);
      expect(isOf('UnsupportedError', UnsupportedError('x')), isTrue);
      expect(isOf('UnimplementedError', UnimplementedError()), isTrue);
      expect(
        isOf('ConcurrentModificationError', ConcurrentModificationError()),
        isTrue,
      );
      expect(isOf('IndexError', IndexError.withLength(5, 1)), isTrue);
      expect(isOf('Error', const FormatException('x')), isFalse);
    });

    test('TypeError from a failed cast', () {
      Object caught;
      try {
        Object x = 1;
        x as String;
        caught = 'no throw';
      } on TypeError catch (e) {
        caught = e;
      }
      expect(isOf('TypeError', caught), isTrue);
    });
  });

  group('is.type against user classes', () {
    // Base (class 0), Derived extends Base (class 1, super 0).
    Interpreter build() {
      final k = ConstantPool();
      final base = k.add('Base');
      final derived = k.add('Derived');
      return Interpreter(
        Module(
          constants: k,
          functions: [
            (BytecodeBuilder()
                  ..emitABx(Op.isType, 0, base)
                  ..emitA(Op.ret, 0))
                .toProto(name: 'isBase', paramCount: 1, registerCount: 1),
            (BytecodeBuilder()
                  ..emitABx(Op.isType, 0, derived)
                  ..emitA(Op.ret, 0))
                .toProto(name: 'isDerived', paramCount: 1, registerCount: 1),
          ],
          classes: const [
            ClassDescriptor(
              name: 'Base',
              fieldCount: 0,
              superIndex: -1,
              methods: {},
            ),
            ClassDescriptor(
              name: 'Derived',
              fieldCount: 0,
              superIndex: 0,
              methods: {},
            ),
          ],
        ),
      );
    }

    test('an instance matches its class and superclasses', () {
      final interp = build();
      final isBase = interp.module.functions[0];
      final isDerived = interp.module.functions[1];
      final derived = InterpInstance(1, 0);
      final base = InterpInstance(0, 0);
      expect(interp.callFunction(isBase, [derived]), isTrue);
      expect(interp.callFunction(isDerived, [derived]), isTrue);
      expect(interp.callFunction(isDerived, [base]), isFalse);
      expect(interp.callFunction(isBase, [42]), isFalse);
    });
  });

  group('as.type', () {
    test('a successful cast returns the value', () {
      expect(asOf('int', 42), 42);
      expect(asOf('String', 'hi'), 'hi');
    });
    test('a failing cast throws', () {
      expect(() => asOf('int', 'x'), throwsA(isA<InterpreterException>()));
    });
  });

  group('EnumValue host bindings', () {
    final registry = HostRegistry.standard();
    const value = EnumValue(enumName: 'Color', index: 1, name: 'green');

    test('index / name / toString resolve on an EnumValue', () {
      expect(registry.resolve(value, 'index')!(value, const []), 1);
      expect(registry.resolve(value, 'name')!(value, const []), 'green');
      expect(
        registry.resolve(value, 'toString')!(value, const []),
        'Color.green',
      );
    });

    test('kind chain places EnumValue before Object', () {
      expect(HostRegistry.kindsOf(value), ['EnumValue', 'Object']);
    });

    test('equality is by (enum, index)', () {
      expect(
        value == const EnumValue(enumName: 'Color', index: 1, name: 'green'),
        isTrue,
      );
      expect(
        value == const EnumValue(enumName: 'Color', index: 2, name: 'blue'),
        isFalse,
      );
      expect(value.hashCode, isA<int>());
    });
  });

  test('load.undef yields the absent-argument sentinel', () {
    final fn =
        (BytecodeBuilder()
              ..emitA(Op.loadUndef, 0)
              ..emitA(Op.ret, 0))
            .toProto(name: 'f', paramCount: 0, registerCount: 1);
    final module = Module(constants: ConstantPool(), functions: [fn]);
    expect(
      identical(Interpreter(module).callFunction(fn, const []), absentArgument),
      isTrue,
    );
  });
}
