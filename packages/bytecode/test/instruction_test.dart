// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('Instruction encoding', () {
    test('packs opcode and operand bytes little-endian by field', () {
      final ins = Instruction.of(Op.addInt, a: 1, b: 2, c: 3);
      expect(ins.op, Op.addInt);
      expect(ins.a, 1);
      expect(ins.b, 2);
      expect(ins.c, 3);
      expect(ins.word, Op.addInt.code | (1 << 8) | (2 << 16) | (3 << 24));
    });

    test('round-trips every opcode with boundary operand bytes', () {
      for (final op in Op.values) {
        final ins = Instruction.of(op, a: 0xFF, b: 0x80, c: 0x01);
        expect(ins.op, op, reason: op.mnemonic);
        expect(ins.a, 0xFF);
        expect(ins.b, 0x80);
        expect(ins.c, 0x01);
      }
    });

    test('bx reads B and C as an unsigned 16-bit value', () {
      final ins = Instruction.of(Op.loadConst, a: 5, b: 0x34, c: 0x12);
      expect(ins.bx, 0x1234);
    });

    test("sbx interprets Bx as signed (two's complement)", () {
      expect(Instruction.of(Op.jz, a: 0, b: 0x00, c: 0x80).sbx, -0x8000);
      expect(Instruction.of(Op.jz, a: 0, b: 0xFF, c: 0x7F).sbx, 0x7FFF);
      expect(Instruction.of(Op.jz, a: 0, b: 0xFF, c: 0xFF).sbx, -1);
    });

    test('ax and sax read A,B,C as a 24-bit value', () {
      final ins = Instruction.of(Op.jmp, a: 0x56, b: 0x34, c: 0x12);
      expect(ins.ax, 0x123456);
      expect(Instruction.of(Op.jmp, a: 0, b: 0, c: 0x80).sax, -0x800000);
      expect(Instruction.of(Op.jmp, a: 0xFF, b: 0xFF, c: 0xFF).sax, -1);
    });
  });

  group('Op', () {
    test('codes are unique', () {
      final codes = Op.values.map((o) => o.code).toSet();
      expect(codes.length, Op.values.length);
    });

    test('fromCode recovers each opcode', () {
      for (final op in Op.values) {
        expect(Op.fromCode(op.code), op);
      }
    });

    test('fromCode throws on an unknown code', () {
      expect(() => Op.fromCode(0xEE), throwsArgumentError);
    });
  });
}
