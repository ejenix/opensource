// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'function_proto.dart';
import 'instruction.dart';
import 'opcode.dart';

/// A branch target. Create one with [BytecodeBuilder.newLabel], mark its
/// position with [BytecodeBuilder.bind], and jump to it before or after it is
/// bound; the builder backpatches displacements when the code is finalized.
class Label {
  int? _target;

  /// Whether this label's position has been fixed with
  /// [BytecodeBuilder.bind].
  bool get isBound => _target != null;
}

class _Fixup {
  _Fixup(this.wordIndex, this.op, this.a, this.label);

  final int wordIndex;
  final Op op;
  final int a;
  final Label label;
}

class _HandlerFixup {
  _HandlerFixup(this.start, this.end, this.target, this.catchReg);
  final Label start;
  final Label end;
  final Label target;
  final int catchReg;
}

/// An assembler that emits a validated instruction stream.
///
/// The builder enforces operand ranges and each opcode's [OperandFormat],
/// resolves label-relative jumps, and emits a wide-mode [Op.pfx] prefix
/// automatically when an [OperandFormat.aBx] index exceeds 16 bits. It is the
/// single supported way to produce bytecode — used by both the compiler backend
/// and hand-written tests — so that no malformed code can be constructed.
class BytecodeBuilder {
  final List<int> _words = [];
  final List<_Fixup> _fixups = [];
  final List<_HandlerFixup> _handlers = [];

  /// The current instruction position, in words, from the start of the stream.
  /// This is where the next emitted instruction will land and what [bind]
  /// records for a label.
  int get position => _words.length;

  /// Allocates a fresh, unbound [Label].
  Label newLabel() => Label();

  /// Fixes [label] at the current [position]. Call this immediately before
  /// emitting the instruction the label should point at.
  void bind(Label label) {
    assert(!label.isBound, 'label already bound');
    label._target = _words.length;
  }

  // --- Format-checked emitters ---

  /// Emits an operand-less instruction (e.g. `ret.void`).
  void emitNone(Op op) {
    assert(
      op.format == OperandFormat.none,
      '${op.mnemonic} is not none-format',
    );
    _words.add(Instruction.of(op).word);
  }

  /// Emits a one-register instruction (e.g. `ret A`, `load.null A`).
  void emitA(Op op, int a) {
    assert(op.format == OperandFormat.a, '${op.mnemonic} is not a-format');
    _checkReg(a);
    _words.add(Instruction.of(op, a: a).word);
  }

  /// Emits a two-register instruction (e.g. `move A, B`, `neg.i A, B`).
  void emitAB(Op op, int a, int b) {
    assert(op.format == OperandFormat.ab, '${op.mnemonic} is not ab-format');
    _checkReg(a);
    _checkReg(b);
    _words.add(Instruction.of(op, a: a, b: b).word);
  }

  /// Emits a three-register instruction (e.g. `add.i A, B, C`).
  void emitABC(Op op, int a, int b, int c) {
    assert(op.format == OperandFormat.abc, '${op.mnemonic} is not abc-format');
    _checkReg(a);
    _checkReg(b);
    _checkReg(c);
    _words.add(Instruction.of(op, a: a, b: b, c: c).word);
  }

  /// Emits a register-plus-index instruction (e.g. `load.const A, Bx`),
  /// prefixing an [Op.pfx] when [index] does not fit in 16 bits.
  void emitABx(Op op, int a, int index) {
    assert(op.format == OperandFormat.aBx, '${op.mnemonic} is not aBx-format');
    _checkReg(a);
    assert(index >= 0, 'index must be non-negative: $index');
    var bx = index;
    if (bx > maxBx) {
      final high = bx >> 16;
      assert(high <= 0xFFFFFF, 'index too large even for pfx: $index');
      _words.add(
        Instruction.of(
          Op.pfx,
          a: high & 0xFF,
          b: (high >> 8) & 0xFF,
          c: (high >> 16) & 0xFF,
        ).word,
      );
      bx &= 0xFFFF;
    }
    _words.add(
      Instruction.of(op, a: a, b: bx & 0xFF, c: (bx >> 8) & 0xFF).word,
    );
  }

  /// Registers a protected region `[start, end)` whose throws jump to [target],
  /// placing the exception in [catchReg]. Labels are resolved at [build] time.
  void addHandler(Label start, Label end, Label target, int catchReg) {
    _handlers.add(_HandlerFixup(start, end, target, catchReg));
  }

  /// Emits `load.int A, imm`, a small signed-integer immediate load. [imm] must
  /// be in `[minSbx, maxSbx]`; larger integers go through the constant pool.
  void emitLoadInt(int a, int imm) {
    _checkReg(a);
    assert(imm >= minSbx && imm <= maxSbx, 'immediate out of range: $imm');
    final raw = imm & 0xFFFF;
    _words.add(
      Instruction.of(Op.loadInt, a: a, b: raw & 0xFF, c: raw >> 8).word,
    );
  }

  /// Emits an unconditional `jmp` to [target].
  void emitJmp(Label target) {
    _fixups.add(_Fixup(_words.length, Op.jmp, 0, target));
    _words.add(0); // placeholder, patched in [build]
  }

  /// Emits a conditional branch (`jz` or `jnz`) on register [a] to [target].
  void emitBranch(Op op, int a, Label target) {
    assert(
      op == Op.jz || op == Op.jnz,
      '${op.mnemonic} is not a conditional branch',
    );
    _checkReg(a);
    _fixups.add(_Fixup(_words.length, op, a, target));
    _words.add(0); // placeholder, patched in [build]
  }

  /// Resolves all pending jumps and returns the finalized instruction stream.
  ///
  /// Throws [StateError] if any jumped-to label was never bound, and
  /// [RangeError] if a displacement does not fit its instruction format.
  Uint32List build() {
    for (final fixup in _fixups) {
      final target = fixup.label._target;
      if (target == null) {
        throw StateError(
          'jump at word ${fixup.wordIndex} targets an '
          'unbound label',
        );
      }
      // pc has already advanced past the jump word when the displacement is
      // applied, so it is relative to the following instruction.
      final offset = target - (fixup.wordIndex + 1);
      final int word;
      if (fixup.op == Op.jmp) {
        if (offset < minSax || offset > maxSax) {
          throw RangeError('jmp displacement $offset out of range');
        }
        final raw = offset & 0xFFFFFF;
        word = Instruction.of(
          Op.jmp,
          a: raw & 0xFF,
          b: (raw >> 8) & 0xFF,
          c: (raw >> 16) & 0xFF,
        ).word;
      } else {
        if (offset < minSbx || offset > maxSbx) {
          throw RangeError('branch displacement $offset out of range');
        }
        final raw = offset & 0xFFFF;
        word = Instruction.of(
          fixup.op,
          a: fixup.a,
          b: raw & 0xFF,
          c: raw >> 8,
        ).word;
      }
      _words[fixup.wordIndex] = word;
    }
    return Uint32List.fromList(_words);
  }

  /// Finalizes the stream and wraps it in a [FunctionProto].
  FunctionProto toProto({
    required String name,
    required int paramCount,
    required int registerCount,
    List<int> captures = const [],
    bool isAsync = false,
    bool isSyncStar = false,
    bool isAsyncStar = false,
  }) {
    final code = build(); // resolves all labels, including handler labels
    final handlers = [
      for (final h in _handlers)
        ExceptionHandler(
          start: h.start._target!,
          end: h.end._target!,
          target: h.target._target!,
          catchReg: h.catchReg,
        ),
    ];
    return FunctionProto(
      name: name,
      paramCount: paramCount,
      registerCount: registerCount,
      code: code,
      captures: captures,
      isAsync: isAsync,
      isSyncStar: isSyncStar,
      isAsyncStar: isAsyncStar,
      handlers: handlers,
    );
  }

  void _checkReg(int r) {
    assert(r >= 0 && r <= 0xFF, 'register out of range [0,255]: $r');
  }
}
