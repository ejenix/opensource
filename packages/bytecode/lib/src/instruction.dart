// Copyright (c) Ejenix authors. MIT license.

import 'opcode.dart';

/// Encoding and decoding of individual 32-bit instruction words.
///
/// A word packs the opcode in the low 8 bits and operand bytes A, B, C in the
/// next three bytes, little-endian by field:
///
/// ```text
///   bits 31..24   23..16   15..8    7..0
///        C         B        A       opcode
/// ```
///
/// This is a pure codec over `int` words; it holds no state. Wider operands and
/// the [Op.pfx] prefix are the concern of higher layers (the assembler and the
/// interpreter's fetch step), not of this encoding.
extension type const Instruction(int word) {
  /// Builds a word from an opcode and three operand bytes.
  ///
  /// Each of [a], [b], [c] must be in `[0, 255]`. Signed operands are encoded
  /// by the assembler before reaching here; this method takes raw bytes.
  factory Instruction.of(Op op, {int a = 0, int b = 0, int c = 0}) {
    assert(a >= 0 && a <= 0xFF, 'operand A out of range: $a');
    assert(b >= 0 && b <= 0xFF, 'operand B out of range: $b');
    assert(c >= 0 && c <= 0xFF, 'operand C out of range: $c');
    return Instruction(op.code | (a << 8) | (b << 16) | (c << 24));
  }

  /// The opcode of this instruction.
  Op get op => Op.fromCode(word & 0xFF);

  /// Operand byte A (bits 8..15).
  int get a => (word >> 8) & 0xFF;

  /// Operand byte B (bits 16..23).
  int get b => (word >> 16) & 0xFF;

  /// Operand byte C (bits 24..31).
  int get c => (word >> 24) & 0xFF;

  /// The unsigned 16-bit operand `Bx = B | (C << 8)`.
  int get bx => (word >> 16) & 0xFFFF;

  /// The signed 16-bit operand `sBx`, two's-complement of [bx].
  int get sbx {
    final v = bx;
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  /// The unsigned 24-bit operand `Ax = A | (B << 8) | (C << 16)`.
  int get ax => (word >> 8) & 0xFFFFFF;

  /// The signed 24-bit operand `sAx`, two's-complement of [ax].
  int get sax {
    final v = ax;
    return v >= 0x800000 ? v - 0x1000000 : v;
  }
}

/// The largest unsigned value expressible in an [OperandFormat.aBx] `Bx` field
/// without a [Op.pfx] prefix.
const int maxBx = 0xFFFF;

/// The inclusive range of an [OperandFormat.aSbx] signed displacement.
const int minSbx = -0x8000;
const int maxSbx = 0x7FFF;

/// The inclusive range of an [OperandFormat.sAx] signed displacement.
const int minSax = -0x800000;
const int maxSax = 0x7FFFFF;
