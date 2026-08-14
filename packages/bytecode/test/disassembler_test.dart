// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('Disassembler', () {
    test('renders a function with resolved constants and jump targets', () {
      final constants = ConstantPool();
      final k = constants.add('hi');

      final b = BytecodeBuilder();
      final end = b.newLabel();
      b
        ..emitABx(Op.loadConst, 0, k)
        ..emitBranch(Op.jz, 0, end)
        ..emitLoadInt(1, 3)
        ..bind(end)
        ..emitA(Op.ret, 0);
      final fn = b.toProto(name: 'greet', paramCount: 0, registerCount: 2);

      final text = Disassembler.disassembleFunction(fn, constants, index: 0);
      expect(text, contains('function F0 greet(0 params, 2 regs)'));
      expect(text, contains('load.const  R0, K0'));
      expect(text, contains('; "hi"'));
      expect(text, contains('jz          R0, @'));
      expect(text, contains('ret         R0'));
    });

    test('folds a pfx prefix into one logical line', () {
      final constants = ConstantPool();
      // Grow the pool past 0xFFFF so the index needs a prefix.
      var idx = 0;
      for (var i = 0; i <= 0x10000; i++) {
        idx = constants.add('s$i');
      }
      final fn = (BytecodeBuilder()..emitABx(Op.loadConst, 0, idx)).toProto(
        name: 'wide',
        paramCount: 0,
        registerCount: 1,
      );

      final text = Disassembler.disassembleFunction(fn, constants);
      // Two words, but a single rendered instruction line for load.const.
      expect('load.const'.allMatches(text).length, 1);
      expect(text, contains('K$idx'));
      expect(text, isNot(contains('pfx')));
    });

    test('renders every operand format', () {
      final constants = ConstantPool();
      final b = BytecodeBuilder();
      final skip = b.newLabel();
      b
        ..emitAB(Op.move, 1, 0)
        ..emitABC(Op.addInt, 2, 0, 1)
        ..emitAB(Op.negInt, 3, 2)
        ..emitABx(Op.loadFunc, 4, 0)
        ..emitJmp(skip)
        ..emitNone(Op.retVoid)
        ..bind(skip)
        ..emitA(Op.ret, 2);
      final fn = b.toProto(name: 'all', paramCount: 1, registerCount: 5);
      final text = Disassembler.disassembleFunction(fn, constants);
      expect(text, contains('move        R1, R0'));
      expect(text, contains('add.i       R2, R0, R1'));
      expect(text, contains('neg.i       R3, R2'));
      expect(text, contains('load.func   R4, F0'));
      expect(text, contains('jmp         @'));
      expect(text, contains('ret.void'));
      expect(text, contains('ret         R2'));
    });

    test('renders load.int immediates and call arg-counts distinctly', () {
      final b = BytecodeBuilder()
        ..emitABx(Op.loadFunc, 0, 0)
        ..emitLoadInt(1, -5) // immediate value, not a jump target
        ..emitABC(Op.call, 0, 0, 1) // callee R0, 1 arg
        ..emitA(Op.ret, 0);
      final fn = b.toProto(name: 'c', paramCount: 1, registerCount: 2);
      final text = Disassembler.disassembleFunction(fn, ConstantPool());
      expect(text, contains('load.int    R1, -5'));
      expect(text, contains('call        R0, _, 1'));
      expect(text, isNot(contains('load.int    R1, @')));
    });

    test('marks the module entry function', () {
      final constants = ConstantPool();
      final main =
          (BytecodeBuilder()
                ..emitLoadInt(0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 1);
      final module = Module(
        constants: constants,
        functions: [main],
        entryFunction: 0,
      );
      final text = Disassembler.disassemble(module);
      expect(text, contains('function F0 main(0 params, 1 regs) (entry)'));
    });
  });
}
