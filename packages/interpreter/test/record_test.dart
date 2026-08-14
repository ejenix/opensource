// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Object? runFn(FunctionProto fn, ConstantPool k) =>
    Interpreter(Module(constants: k, functions: [fn], entryFunction: 0)).run();

void main() {
  group('record.new / record.get (hand-built bytecode)', () {
    test(r'builds a positional record and reads $1 / $2', () {
      final k = ConstantPool();
      final shape = k.add('2');
      final f1 = k.add(r'$1');
      final f2 = k.add(r'$2');
      // R0..R1 = (10, 20); build into R0; read $1 -> R0, $2 -> R1; R0 = R0*.. no,
      // just return $2 to prove positional indexing.
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 10)
                ..emitLoadInt(1, 20)
                ..emitABx(Op.recordNew, 0, shape) // R0 = (10, 20)
                ..emitAB(Op.move, 1, 0)
                ..emitABx(Op.recordGet, 1, f2) // R1 = R0.$2 = 20
                ..emitABx(Op.recordGet, 0, f1) // R0 = R0.$1 = 10
                ..emitABC(Op.addInt, 0, 0, 1) // 10 + 20
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 2);
      expect(runFn(fn, k), 30);
    });

    test('builds a named record and reads a named field', () {
      final k = ConstantPool();
      final shape = k.add('0;x,y'); // 0 positional, named x,y
      final fy = k.add('y');
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 3) // x
                ..emitLoadInt(1, 4) // y
                ..emitABx(Op.recordNew, 0, shape) // R0 = (x: 3, y: 4)
                ..emitABx(Op.recordGet, 0, fy) // R0 = R0.y = 4
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 2);
      expect(runFn(fn, k), 4);
    });

    test('mixed positional and named fields', () {
      final k = ConstantPool();
      final shape = k.add('1;tag'); // 1 positional, named tag
      final f1 = k.add(r'$1');
      final ftag = k.add('tag');
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 7) // positional $1
                ..emitLoadInt(1, 9) // named tag
                ..emitABx(Op.recordNew, 0, shape)
                ..emitAB(Op.move, 1, 0)
                ..emitABx(Op.recordGet, 1, ftag) // R1 = tag = 9
                ..emitABx(Op.recordGet, 0, f1) // R0 = $1 = 7
                ..emitABC(Op.mulInt, 0, 0, 1) // 7 * 9 = 63
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 2);
      expect(runFn(fn, k), 63);
    });

    test('the built value is an InterpRecord', () {
      final k = ConstantPool();
      final shape = k.add('1');
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 1)
                ..emitABx(Op.recordNew, 0, shape)
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 1);
      expect(runFn(fn, k), isA<InterpRecord>());
    });
  });
}
