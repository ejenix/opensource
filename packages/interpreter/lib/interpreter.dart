// Copyright (c) Ejenix authors. MIT license.

/// The register-based bytecode interpreter.
///
/// Construct an [Interpreter] over a `Module` from `package:ejenix_bytecode`
/// and call [Interpreter.run] to execute its entry function. Sandbox limits and
/// opcode profiling are constructor options. Faults raised by the VM are
/// [InterpreterException]s; exceptions escaping the interpreted program are
/// [InterpreterUncaughtException]s.
library;

export 'src/errors.dart';
export 'src/host_api.dart';
export 'src/interpreter.dart';
export 'src/preflight.dart';
export 'src/profile.dart';
