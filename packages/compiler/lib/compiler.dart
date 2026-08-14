// Copyright (c) Ejenix authors. MIT license.

/// Compiles a subset of Dart source to Ejenix bytecode.
///
/// Use [Compiler.compileSource] or [Compiler.compileFile] to obtain a
/// [CompileResult]. On success, [CompileResult.module] is a `Module` from
/// `package:ejenix_bytecode` ready to serialize into a bundle or execute. On
/// failure, [CompileResult.diagnostics] carries actionable, located errors.
///
/// The supported Dart subset and its diagnostics are specified in
/// `spec/dart-subset.md`.
library;

export 'src/compiler.dart';
export 'src/diagnostic.dart';
