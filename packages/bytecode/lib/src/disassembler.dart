// Copyright (c) Ejenix authors. MIT license.

import 'constant_pool.dart';
import 'function_proto.dart';
import 'instruction.dart';
import 'module.dart';
import 'opcode.dart';

/// Renders bytecode as human-readable text.
///
/// The output is a debugging and documentation aid (it backs `ejenix inspect`
/// and the worked examples in `spec/bytecode.md`); it is not a wire format and
/// makes no stability guarantees. Wide-mode [Op.pfx] prefixes are folded into
/// the following instruction's index so the listing reads one logical
/// instruction per line.
class Disassembler {
  /// Disassembles an entire [module], one section per function.
  static String disassemble(Module module) {
    final buffer = StringBuffer();
    for (var i = 0; i < module.functions.length; i++) {
      if (i > 0) buffer.writeln();
      final marker = i == module.entryFunction ? ' (entry)' : '';
      buffer.write(
        disassembleFunction(
          module.functions[i],
          module.constants,
          index: i,
        ).replaceFirst('\n', '$marker\n'),
      );
    }
    return buffer.toString();
  }

  /// Disassembles a single [fn], resolving pool references against
  /// [constants]. [index] is the function's position in its module, shown in
  /// the header when non-negative.
  static String disassembleFunction(
    FunctionProto fn,
    ConstantPool constants, {
    int index = -1,
  }) {
    final buffer = StringBuffer();
    final id = index >= 0 ? 'F$index ' : '';
    buffer.writeln(
      'function $id${fn.name}('
      '${fn.paramCount} params, ${fn.registerCount} regs)',
    );

    final code = fn.code;
    var pc = 0;
    while (pc < code.length) {
      final addr = pc;
      var word = Instruction(code[pc]);
      pc++;

      // Fold a wide-mode prefix into the following instruction's index.
      var pfxHigh = 0;
      if (word.op == Op.pfx) {
        pfxHigh = word.ax;
        word = Instruction(code[pc]);
        pc++;
      }

      buffer.writeln(
        '  ${_addr(addr)}  ${_format(word, pfxHigh, pc, constants)}',
      );
    }
    return buffer.toString();
  }

  static String _format(
    Instruction ins,
    int pfxHigh,
    int nextPc,
    ConstantPool constants,
  ) {
    final op = ins.op;
    final name = op.mnemonic.padRight(11);
    switch (op.format) {
      case OperandFormat.none:
        return op.mnemonic;
      case OperandFormat.a:
        return '$name R${ins.a}';
      case OperandFormat.ab:
        return '$name R${ins.a}, R${ins.b}';
      case OperandFormat.abc:
        // `call` uses C as an argument count, not a third register operand.
        if (op == Op.call) {
          return '$name R${ins.a}, _, ${ins.c}';
        }
        return '$name R${ins.a}, R${ins.b}, R${ins.c}';
      case OperandFormat.aBx:
        final bx = (pfxHigh << 16) | ins.bx;
        if (op == Op.loadConst && bx < constants.length) {
          return '$name R${ins.a}, K$bx           ; ${_literal(constants[bx])}';
        }
        final tag = switch (op) {
          Op.loadFunc || Op.closureNew => 'F',
          Op.invokeDyn => 'call',
          Op.upvalGet => 'U',
          _ => 'K',
        };
        return '$name R${ins.a}, $tag$bx';
      case OperandFormat.aSbx:
        // `load.int` carries a signed immediate value; branches carry a
        // signed displacement resolved to an absolute target address.
        if (op == Op.loadInt) {
          return '$name R${ins.a}, ${ins.sbx}';
        }
        final target = nextPc + ins.sbx;
        return '$name R${ins.a}, @${_addr(target)}';
      case OperandFormat.sAx:
        // pfx is folded above and never reaches here; only jmp does.
        final target = nextPc + ins.sax;
        return '$name @${_addr(target)}';
    }
  }

  static String _addr(int pc) => pc.toString().padLeft(4, '0');

  static String _literal(Object? value) {
    if (value is String) return '"$value"';
    return '$value';
  }
}
