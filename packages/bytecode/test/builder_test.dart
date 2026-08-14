// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('BytecodeBuilder', () {
    test('emits format-checked instructions', () {
      final b = BytecodeBuilder()
        ..emitLoadInt(0, 7)
        ..emitLoadInt(1, 5)
        ..emitABC(Op.addInt, 2, 0, 1)
        ..emitA(Op.ret, 2);
      final code = b.build();
      expect(code.length, 4);
      expect(Instruction(code[0]).op, Op.loadInt);
      expect(Instruction(code[2]).op, Op.addInt);
      expect(Instruction(code[2]).a, 2);
    });

    test('load.int encodes negative immediates', () {
      final code = (BytecodeBuilder()..emitLoadInt(0, -1234)).build();
      // Decoded as sBx via the Bx field.
      expect(Instruction(code[0]).sbx, -1234);
    });

    test('resolves a forward jump', () {
      final b = BytecodeBuilder();
      final end = b.newLabel();
      b
        ..emitBranch(Op.jz, 0, end) // word 0
        ..emitLoadInt(1, 99) // word 1 (skipped when R0 is false)
        ..bind(end)
        ..emitA(Op.ret, 1); // word 2
      final code = b.build();
      // Branch at word 0; target is word 2; pc after fetch is 1; offset = 1.
      expect(Instruction(code[0]).sbx, 1);
    });

    test('resolves a backward jump', () {
      final b = BytecodeBuilder();
      final top = b.newLabel();
      b
        ..bind(top) // word 0
        ..emitLoadInt(0, 1) // word 0
        ..emitJmp(top); // word 1 -> back to 0
      final code = b.build();
      // jmp at word 1; pc after fetch is 2; target 0; offset = -2.
      expect(Instruction(code[1]).sax, -2);
    });

    test('auto-emits a pfx prefix for a wide constant index', () {
      final code = (BytecodeBuilder()..emitABx(Op.loadConst, 3, 0x12345))
          .build();
      expect(code.length, 2);
      expect(Instruction(code[0]).op, Op.pfx);
      expect(Instruction(code[0]).ax, 0x1); // high bits: 0x12345 >> 16
      final low = Instruction(code[1]);
      expect(low.op, Op.loadConst);
      expect((Instruction(code[0]).ax << 16) | low.bx, 0x12345);
    });

    test('no pfx for an index that fits in 16 bits', () {
      final code = (BytecodeBuilder()..emitABx(Op.loadConst, 0, 0xFFFF))
          .build();
      expect(code.length, 1);
      expect(Instruction(code[0]).bx, 0xFFFF);
    });

    test('throws when a jumped-to label is never bound', () {
      final b = BytecodeBuilder();
      b.emitJmp(b.newLabel());
      expect(b.build, throwsStateError);
    });

    test('throws when a branch displacement overflows sBx', () {
      final b = BytecodeBuilder();
      final top = b.newLabel();
      b.bind(top);
      for (var i = 0; i < 33000; i++) {
        b.emitNone(Op.retVoid);
      }
      b.emitBranch(Op.jnz, 0, top); // offset < -32768
      expect(b.build, throwsRangeError);
    });

    test('toProto wraps the finalized stream', () {
      final proto = (BytecodeBuilder()..emitNone(Op.retVoid)).toProto(
        name: 'f',
        paramCount: 0,
        registerCount: 1,
      );
      expect(proto.name, 'f');
      expect(proto.code.length, 1);
      expect(proto.handlers, isEmpty);
    });

    test('toProto resolves handler labels to instruction offsets', () {
      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..emitNone(Op.retVoid) // offset 0 (outside the region)
        ..bind(start) // offset 1
        ..emitLoadInt(0, 1)
        ..emitA(Op.throwValue, 0)
        ..bind(end) // offset 3
        ..emitA(Op.ret, 0)
        ..bind(target) // offset 4
        ..emitA(Op.ret, 0)
        ..addHandler(start, end, target, 2);
      final proto = b.toProto(name: 'f', paramCount: 0, registerCount: 3);
      final h = proto.handlers.single;
      expect(h.start, 1);
      expect(h.end, 3);
      expect(h.target, 4);
      expect(h.catchReg, 2);
    });

    test('toProto resolves multiple handlers in registration order', () {
      final b = BytecodeBuilder();
      final s1 = b.newLabel();
      final s2 = b.newLabel();
      b
        ..bind(s1)
        ..emitNone(Op.retVoid)
        ..bind(s2)
        ..emitNone(Op.retVoid)
        ..addHandler(s1, s2, s2, 0)
        ..addHandler(s2, s2, s1, 1);
      final proto = b.toProto(name: 'f', paramCount: 0, registerCount: 2);
      expect(proto.handlers, hasLength(2));
      expect(proto.handlers[0].catchReg, 0);
      expect(proto.handlers[1].catchReg, 1);
    });

    test('rejects mismatched operand formats via assertions', () {
      final b = BytecodeBuilder();
      expect(() => b.emitABC(Op.ret, 0, 0, 0), throwsA(isA<AssertionError>()));
      expect(() => b.emitA(Op.addInt, 0), throwsA(isA<AssertionError>()));
      expect(() => b.emitNone(Op.addInt), throwsA(isA<AssertionError>()));
      expect(() => b.emitAB(Op.ret, 0, 0), throwsA(isA<AssertionError>()));
      expect(
        () => b.emitBranch(Op.jmp, 0, b.newLabel()),
        throwsA(isA<AssertionError>()),
      );
    });

    test('tracks position and emits ab-format instructions', () {
      final b = BytecodeBuilder();
      expect(b.position, 0);
      b.emitAB(Op.move, 1, 0);
      b.emitAB(Op.negInt, 2, 1);
      expect(b.position, 2);
      final code = b.build();
      expect(Instruction(code[0]).op, Op.move);
      expect(Instruction(code[1]).op, Op.negInt);
      expect(Instruction(code[1]).a, 2);
      expect(Instruction(code[1]).b, 1);
    });
  });
}
