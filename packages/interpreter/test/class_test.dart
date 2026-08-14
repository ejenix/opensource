// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  // Models:  class Point { int x, y; int sum() => x + y; }
  // constructed as Point(3, 4), then p.sum().
  FunctionProto constructor() =>
      (BytecodeBuilder()
            ..emitABC(Op.storeField, 0, 0, 1) // this.field[0] = x (R1)
            ..emitABC(Op.storeField, 0, 1, 2) // this.field[1] = y (R2)
            ..emitNone(Op.retVoid))
          .toProto(name: 'Point.', paramCount: 3, registerCount: 3);

  FunctionProto sumMethod() =>
      (BytecodeBuilder()
            ..emitABC(Op.loadField, 1, 0, 0) // R1 = this.field[0]
            ..emitABC(Op.loadField, 2, 0, 1) // R2 = this.field[1]
            ..emitABC(Op.addInt, 1, 1, 2)
            ..emitA(Op.ret, 1))
          .toProto(name: 'Point.sum', paramCount: 1, registerCount: 3);

  FunctionProto main() =>
      (BytecodeBuilder()
            ..emitABx(Op.alloc, 0, 0) // R0 = new Point
            ..emitABx(Op.loadFunc, 1, 0) // R1 = constructor
            ..emitAB(Op.move, 2, 0) // R2 = this
            ..emitLoadInt(3, 3) // R3 = 3
            ..emitLoadInt(4, 4) // R4 = 4
            ..emitABC(Op.call, 1, 0, 3) // Point.(this, 3, 4)
            ..emitAB(Op.move, 1, 0) // R1 = receiver copy
            ..emitABx(Op.invokeDyn, 1, 0) // R1 = R0.sum()
            ..emitA(Op.ret, 1))
          .toProto(name: 'main', paramCount: 0, registerCount: 5);

  Module module() => Module(
    constants: ConstantPool(),
    functions: [constructor(), sumMethod(), main()],
    entryFunction: 2,
    callSites: const [CallSite(selector: 'sum', argCount: 0)],
    classes: const [
      ClassDescriptor(
        name: 'Point',
        fieldCount: 2,
        superIndex: -1,
        methods: {'sum': 1},
        fields: {'x': 0, 'y': 1},
      ),
    ],
  );

  test('constructs an instance, mutates fields, and dispatches a method', () {
    expect(Interpreter(module()).run(), 7);
  });

  test('a dynamic field getter reads a field by name', () {
    // invoke.dyn 'x' (0 args) on a Point falls through to the field getter.
    final m = module();
    final getX =
        (BytecodeBuilder()
              ..emitABx(Op.alloc, 0, 0)
              ..emitABx(Op.loadFunc, 1, 0)
              ..emitAB(Op.move, 2, 0)
              ..emitLoadInt(3, 8)
              ..emitLoadInt(4, 9)
              ..emitABC(Op.call, 1, 0, 3)
              ..emitAB(Op.move, 1, 0)
              ..emitABx(Op.invokeDyn, 1, 1) // R0.x
              ..emitA(Op.ret, 1))
            .toProto(name: 'main', paramCount: 0, registerCount: 5);
    final withGetter = Module(
      constants: ConstantPool(),
      functions: [m.functions[0], m.functions[1], getX],
      entryFunction: 2,
      callSites: const [
        CallSite(selector: 'sum', argCount: 0),
        CallSite(selector: 'x', argCount: 0),
      ],
      classes: m.classes,
    );
    expect(Interpreter(withGetter).run(), 8);
  });

  test('an unknown selector on an instance faults', () {
    final m = module();
    final bad =
        (BytecodeBuilder()
              ..emitABx(Op.alloc, 0, 0)
              ..emitAB(Op.move, 1, 0)
              ..emitABx(Op.invokeDyn, 1, 1) // 'ghost'
              ..emitA(Op.ret, 1))
            .toProto(name: 'main', paramCount: 0, registerCount: 2);
    final module2 = Module(
      constants: ConstantPool(),
      functions: [m.functions[0], m.functions[1], bad],
      entryFunction: 2,
      callSites: const [
        CallSite(selector: 'sum', argCount: 0),
        CallSite(selector: 'ghost', argCount: 0),
      ],
      classes: m.classes,
    );
    expect(
      () => Interpreter(module2).run(),
      throwsA(
        isA<InterpreterException>().having(
          (e) => e.message,
          'message',
          contains('no method'),
        ),
      ),
    );
  });
}
