// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  FunctionProto proto(String name) => (BytecodeBuilder()..emitNone(Op.retVoid))
      .toProto(name: name, paramCount: 0, registerCount: 1);

  group('Module', () {
    test('entry returns the entry function when set', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [proto('main')],
        entryFunction: 0,
      );
      expect(module.entry?.name, 'main');
    });

    test('entry is null for a library module', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [proto('helper')],
      );
      expect(module.entry, isNull);
      expect(module.entryFunction, -1);
    });

    test('asserts entryFunction is in range', () {
      expect(
        () => Module(
          constants: ConstantPool(),
          functions: [proto('a')],
          entryFunction: 5,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
