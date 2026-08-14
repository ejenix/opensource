// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  group('capture by reference', () {
    // Models:
    //   int outer() {
    //     var n = 5;
    //     int get() => n;          // captures n
    //     void bump() { n = n+1; } // mutates the shared cell
    //     bump();
    //     return get();            // observes bump()'s mutation -> 6
    //   }
    FunctionProto outer() =>
        (BytecodeBuilder()
              ..emitLoadInt(0, 5) // R0 = 5
              ..emitA(Op.cellNew, 0) // box n into a cell
              ..emitABx(Op.closureNew, 1, 1) // R1 = get (captures R0)
              ..emitABx(Op.closureNew, 2, 2) // R2 = bump (captures R0)
              ..emitABC(Op.call, 2, 0, 0) // bump()
              ..emitABC(Op.call, 1, 0, 0) // R1 = get()
              ..emitA(Op.ret, 1))
            .toProto(name: 'outer', paramCount: 0, registerCount: 3);

    FunctionProto getFn() =>
        (BytecodeBuilder()
              ..emitABx(Op.upvalGet, 0, 0) // R0 = upvalue 0 (the cell)
              ..emitAB(Op.cellGet, 0, 0) // R0 = cell.value
              ..emitA(Op.ret, 0))
            .toProto(
              name: 'outer.get',
              paramCount: 0,
              registerCount: 1,
              captures: const [0],
            );

    FunctionProto bumpFn() =>
        (BytecodeBuilder()
              ..emitABx(Op.upvalGet, 0, 0) // R0 = cell
              ..emitAB(Op.cellGet, 1, 0) // R1 = cell.value
              ..emitLoadInt(2, 1) // R2 = 1
              ..emitABC(Op.addInt, 1, 1, 2) // R1 = value + 1
              ..emitAB(Op.cellSet, 0, 1) // cell.value = R1
              ..emitNone(Op.retVoid))
            .toProto(
              name: 'outer.bump',
              paramCount: 0,
              registerCount: 3,
              captures: const [0],
            );

    test('a closure observes mutations made through a shared cell', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [outer(), getFn(), bumpFn()],
        entryFunction: 0,
      );
      expect(Interpreter(module).run(), 6);
    });
  });

  group('closures through host higher-order methods', () {
    // Models:
    //   int mapAddBase() {
    //     var base = 100;
    //     var xs = <Object?>[]..add(1)..add(2);
    //     var ys = xs.map((e) => e + base);  // [101, 102]
    //     return ys[0];                      // 101
    //   }
    FunctionProto mapAddBase() =>
        (BytecodeBuilder()
              ..emitLoadInt(0, 100) // R0 = 100
              ..emitA(Op.cellNew, 0) // box base
              ..emitA(Op.listNew, 1) // R1 = xs
              ..emitAB(Op.move, 2, 1) // R2 = xs (receiver)
              ..emitLoadInt(3, 1) // R3 = 1
              ..emitABx(Op.invokeDyn, 2, 0) // xs.add(1)
              ..emitAB(Op.move, 2, 1)
              ..emitLoadInt(3, 2) // R3 = 2
              ..emitABx(Op.invokeDyn, 2, 0) // xs.add(2)
              ..emitAB(Op.move, 2, 1) // R2 = xs (receiver for map)
              ..emitABx(Op.closureNew, 3, 1) // R3 = (e) => e + base
              ..emitABx(Op.invokeDyn, 2, 1) // R2 = xs.map(f) -> [101, 102]
              ..emitAB(Op.move, 3, 2) // R3 = ys (receiver)
              ..emitLoadInt(4, 0) // R4 = index 0
              ..emitABx(Op.invokeDyn, 3, 2) // R3 = ys[0] = 101
              ..emitA(Op.ret, 3))
            .toProto(name: 'mapAddBase', paramCount: 0, registerCount: 5);

    FunctionProto addBase() =>
        (BytecodeBuilder()
              ..emitABx(Op.upvalGet, 1, 0) // R1 = base cell
              ..emitAB(Op.cellGet, 1, 1) // R1 = base value
              ..emitABC(Op.addInt, 0, 0, 1) // R0 = e + base
              ..emitA(Op.ret, 0))
            .toProto(
              name: 'mapAddBase.f',
              paramCount: 1,
              registerCount: 2,
              captures: const [0],
            );

    test('map invokes a capturing closure via the host bridge', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [mapAddBase(), addBase()],
        entryFunction: 0,
        callSites: const [
          CallSite(selector: 'add', argCount: 1),
          CallSite(selector: 'map', argCount: 1),
          CallSite(selector: '[]', argCount: 1),
        ],
      );
      expect(Interpreter(module).run(), 101);
    });

    // Models:
    //   int sumViaFold() {
    //     var xs = <Object?>[]..add(1)..add(2)..add(3);
    //     return xs.fold(0, (acc, e) => acc + e);  // 6
    //   }
    // Exercises a two-argument closure marshalled through the host bridge.
    FunctionProto sumViaFold() {
      final b = BytecodeBuilder()..emitA(Op.listNew, 0);
      for (final v in [1, 2, 3]) {
        b
          ..emitAB(Op.move, 1, 0)
          ..emitLoadInt(2, v)
          ..emitABx(Op.invokeDyn, 1, 0); // xs.add(v)
      }
      b
        ..emitAB(Op.move, 1, 0) // R1 = xs (receiver)
        ..emitLoadInt(2, 0) // R2 = seed
        ..emitABx(Op.closureNew, 3, 1) // R3 = combiner (no captures)
        ..emitABx(Op.invokeDyn, 1, 1) // R1 = xs.fold(0, combiner)
        ..emitA(Op.ret, 1);
      return b.toProto(name: 'sumViaFold', paramCount: 0, registerCount: 4);
    }

    FunctionProto combiner() =>
        (BytecodeBuilder()
              ..emitABC(Op.addInt, 0, 0, 1) // R0 = acc + e
              ..emitA(Op.ret, 0))
            .toProto(name: 'combiner', paramCount: 2, registerCount: 2);

    test('fold invokes a two-argument closure via the host bridge', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [sumViaFold(), combiner()],
        entryFunction: 0,
        callSites: const [
          CallSite(selector: 'add', argCount: 1),
          CallSite(selector: 'fold', argCount: 2),
        ],
      );
      expect(Interpreter(module).run(), 6);
    });
  });
}
