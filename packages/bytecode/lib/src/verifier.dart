// Copyright (c) Ejenix authors. MIT license.

import 'function_proto.dart';
import 'instruction.dart';
import 'module.dart';
import 'opcode.dart';

/// A structural defect found in a decoded module.
class VerificationError {
  VerificationError(this.message, {this.function, this.pc});

  /// What is wrong, in terms an operator can act on.
  final String message;

  /// The function the defect is in, if it is inside one.
  final String? function;

  /// The word offset within that function, if applicable.
  final int? pc;

  @override
  String toString() {
    final where = function == null
        ? ''
        : ' in $function${pc == null ? '' : '+$pc'}';
    return 'bytecode verification failed$where: $message';
  }
}

/// Thrown when a module fails [verifyModule].
class ModuleVerificationException implements Exception {
  ModuleVerificationException(this.errors);

  /// Every defect found, in discovery order.
  final List<VerificationError> errors;

  @override
  String toString() =>
      'module failed verification with ${errors.length} error(s):\n'
      '${errors.map((e) => '  - $e').join('\n')}';
}

/// Ceilings on module size, applied before a module is trusted enough to run.
class VerifyLimits {
  const VerifyLimits({
    this.maxFunctions = 65536,
    this.maxCodeWords = 1 << 22,
    this.maxRegisters = 256,
    this.maxClasses = 65536,
    this.maxHandlers = 4096,
  });

  final int maxFunctions;
  final int maxCodeWords;

  /// A register index is one byte, so 256 is the hard encoding ceiling.
  final int maxRegisters;
  final int maxClasses;
  final int maxHandlers;
}

/// Checks that [module] is structurally safe to execute, and returns every
/// defect found rather than only the first.
///
/// **Why this exists.** A signature proves *origin*, not *safety*. It says the
/// bytes came from a holder of the signing key; it says nothing about whether
/// the module indexes a register that does not exist, jumps outside its own
/// code, or names a constant past the end of the pool. A leaked key, a
/// compiler bug, a truncated encoder, or a hand-built module all produce
/// artifacts that verify cryptographically and are structurally nonsense.
///
/// Until now those invariants were expressed as Dart `assert`s — which are
/// **stripped from release builds**. They held while developing and vanished on
/// the devices that matter.
///
/// The interpreter indexes registers, constants, and functions directly. An
/// out-of-range index is not a caught error there; it is undefined behaviour in
/// the host. This runs after decode and before staging, so nothing unverified
/// is ever executed.
List<VerificationError> verifyModule(
  Module module, {
  VerifyLimits limits = const VerifyLimits(),
}) {
  final errors = <VerificationError>[];
  void bad(String m, {String? fn, int? pc}) =>
      errors.add(VerificationError(m, function: fn, pc: pc));

  // --- module-level shape ---
  if (module.functions.length > limits.maxFunctions) {
    bad('${module.functions.length} functions exceeds ${limits.maxFunctions}');
  }
  if (module.classes.length > limits.maxClasses) {
    bad('${module.classes.length} classes exceeds ${limits.maxClasses}');
  }
  if (module.globalCount < 0) bad('negative globalCount ${module.globalCount}');

  bool validFn(int i) => i >= 0 && i < module.functions.length;

  if (module.entryFunction != -1 && !validFn(module.entryFunction)) {
    bad('entryFunction ${module.entryFunction} is not a function index');
  }
  if (module.staticInit != -1 && !validFn(module.staticInit)) {
    bad('staticInit ${module.staticInit} is not a function index');
  }

  // --- classes: indices valid, inheritance acyclic ---
  for (var ci = 0; ci < module.classes.length; ci++) {
    final cls = module.classes[ci];
    if (cls.fieldCount < 0) bad('class ${cls.name} has negative fieldCount');
    if (cls.superIndex != -1 &&
        (cls.superIndex < 0 || cls.superIndex >= module.classes.length)) {
      bad('class ${cls.name} superIndex ${cls.superIndex} out of range');
    }
    for (final entry in cls.methods.entries) {
      if (!validFn(entry.value)) {
        bad(
          'class ${cls.name}.${entry.key} -> function ${entry.value} '
          'out of range',
        );
      }
    }
  }
  // A cycle would make method resolution loop forever inside the host.
  for (var ci = 0; ci < module.classes.length; ci++) {
    var seen = 0;
    var at = module.classes[ci].superIndex;
    while (at != -1 && at >= 0 && at < module.classes.length) {
      if (++seen > module.classes.length) {
        bad('class ${module.classes[ci].name} has a cyclic superclass chain');
        break;
      }
      at = module.classes[at].superIndex;
    }
  }

  // --- each function ---
  for (final fn in module.functions) {
    _verifyFunction(fn, module, limits, bad);
  }
  return errors;
}

void _verifyFunction(
  FunctionProto fn,
  Module module,
  VerifyLimits limits,
  void Function(String, {String? fn, int? pc}) bad,
) {
  final name = fn.name;
  final code = fn.code;

  if (fn.registerCount < 0 || fn.registerCount > limits.maxRegisters) {
    bad(
      'registerCount ${fn.registerCount} outside [0, ${limits.maxRegisters}]',
      fn: name,
    );
    return; // Every register check below would be meaningless.
  }
  if (fn.paramCount < 0 || fn.paramCount > fn.registerCount) {
    bad(
      'paramCount ${fn.paramCount} exceeds registerCount ${fn.registerCount}',
      fn: name,
    );
  }
  if (code.length > limits.maxCodeWords) {
    bad('${code.length} code words exceeds ${limits.maxCodeWords}', fn: name);
    return;
  }
  if (fn.handlers.length > limits.maxHandlers) {
    bad(
      '${fn.handlers.length} handlers exceeds ${limits.maxHandlers}',
      fn: name,
    );
  }

  void reg(int r, int pc, String what) {
    if (r < 0 || r >= fn.registerCount) {
      bad(
        '$what register $r outside [0, ${fn.registerCount})',
        fn: name,
        pc: pc,
      );
    }
  }

  // A jump may land only on an instruction boundary that is not the tail of a
  // pfx pair — otherwise control resumes mid-operand.
  void target(int t, int pc) {
    if (t < 0 || t >= code.length) {
      bad('jump target $t outside code [0, ${code.length})', fn: name, pc: pc);
    }
  }

  var pendingPfx = false;
  for (var pc = 0; pc < code.length; pc++) {
    final ins = Instruction(code[pc]);
    final Op op;
    try {
      op = Op.fromCode(code[pc] & 0xFF);
    } on ArgumentError {
      bad(
        'unknown opcode 0x${(code[pc] & 0xFF).toRadixString(16)}',
        fn: name,
        pc: pc,
      );
      pendingPfx = false;
      continue;
    }

    if (pendingPfx && op.format != OperandFormat.aBx) {
      bad(
        'pfx must precede an aBx instruction, found ${op.mnemonic}',
        fn: name,
        pc: pc,
      );
    }
    pendingPfx = op == Op.pfx;
    if (op == Op.pfx && pc == code.length - 1) {
      bad('pfx is the last word; nothing follows it', fn: name, pc: pc);
    }

    switch (op.format) {
      case OperandFormat.none:
        break;
      case OperandFormat.a:
        reg(ins.a, pc, 'A');
      case OperandFormat.ab:
        reg(ins.a, pc, 'A');
        reg(ins.b, pc, 'B');
      case OperandFormat.abc:
        reg(ins.a, pc, 'A');
        reg(ins.b, pc, 'B');
        reg(ins.c, pc, 'C');
      case OperandFormat.aBx:
        reg(ins.a, pc, 'A');
        _checkIndex(op, ins.bx, module, name, pc, bad);
      case OperandFormat.aSbx:
        reg(ins.a, pc, 'A');
        // Format does not imply meaning: `load.int` is aSbx too, and its
        // signed field is a literal, not a displacement. Only the branches
        // name a code position.
        if (op == Op.jz || op == Op.jnz) target(pc + 1 + ins.sbx, pc);
      case OperandFormat.sAx:
        // Likewise sAx: `jmp` displaces, `pfx` carries the high bits of the
        // following instruction's index.
        if (op == Op.jmp) target(pc + 1 + ins.sax, pc);
    }
  }

  // --- exception handlers ---
  for (final h in fn.handlers) {
    if (h.start < 0 || h.start > code.length) {
      bad('handler start ${h.start} outside code', fn: name);
    }
    if (h.end < h.start || h.end > code.length) {
      bad('handler end ${h.end} before start or outside code', fn: name);
    }
    if (h.target < 0 || h.target >= code.length) {
      bad('handler target ${h.target} outside code', fn: name);
    }
    if (h.catchReg < 0 || h.catchReg >= fn.registerCount) {
      bad(
        'handler catch register ${h.catchReg} outside '
        '[0, ${fn.registerCount})',
        fn: name,
      );
    }
  }
}

/// Range-checks the table an aBx index refers to.
///
/// The interpreter indexes these lists directly, so an out-of-range value is
/// not a recoverable error there — it is undefined behaviour in the host.
void _checkIndex(
  Op op,
  int bx,
  Module module,
  String fnName,
  int pc,
  void Function(String, {String? fn, int? pc}) bad,
) {
  void range(int max, String what) {
    if (bx < 0 || bx >= max) {
      bad('$what index $bx outside [0, $max)', fn: fnName, pc: pc);
    }
  }

  switch (op) {
    case Op.loadConst:
      range(module.constants.length, 'constant');
    case Op.loadFunc:
      range(module.functions.length, 'function');
    case Op.invokeDyn:
      range(module.callSites.length, 'call site');
    case Op.invokeStatic:
      range(module.callSites.length, 'call site');
    case Op.alloc:
      range(module.classes.length, 'class');
    case Op.loadGlobal:
    case Op.storeGlobal:
      range(module.globalCount, 'global');
    default:
      // Other aBx opcodes carry counts or small immediates, not table indices.
      break;
  }
}

/// Verifies [module] and throws if it is not structurally safe.
void verifyModuleOrThrow(
  Module module, {
  VerifyLimits limits = const VerifyLimits(),
}) {
  final errors = verifyModule(module, limits: limits);
  if (errors.isNotEmpty) throw ModuleVerificationException(errors);
}
