// Copyright (c) Ejenix authors. MIT license.

/// The Ejenix bytecode: instruction set, encoding, constant
/// pool, function prototypes, module container, assembler, and disassembler.
///
/// This package is the foundation of the stack and depends on nothing. The
/// compiler emits a [Module] through a [BytecodeBuilder]; the interpreter
/// executes one; the bundle format serializes one. The normative description of
/// every opcode and encoding rule is `spec/bytecode.md`.
library;

export 'src/builder.dart';
export 'src/constant_pool.dart';
export 'src/disassembler.dart';
export 'src/enum_value.dart';
export 'src/record_value.dart';
export 'src/function_proto.dart';
export 'src/instruction.dart';
export 'src/module.dart';
export 'src/opcode.dart';
