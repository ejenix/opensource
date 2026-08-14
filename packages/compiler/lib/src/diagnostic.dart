// Copyright (c) Ejenix authors. MIT license.

/// A human-readable name for an analyzer AST node's kind, with the analyzer's
/// internal `Impl` suffix stripped (e.g. `SwitchExpressionImpl` →
/// `SwitchExpression`). Used in "not yet supported" diagnostics so messages
/// name the construct the way the language does, not the implementation class.
String astKindName(Object node) =>
    node.runtimeType.toString().replaceFirst(RegExp(r'Impl$'), '');

/// The severity of a [CompileDiagnostic].
enum DiagnosticSeverity {
  /// A fatal problem: no module is produced.
  error,

  /// A non-fatal concern; compilation still succeeds.
  warning,
}

/// A single compiler message anchored to a source location.
///
/// Diagnostics are modeled on the quality bar of the Elm and Rust compilers
/// (brief §6.2): every one carries a `path:line:column`, a plain-language
/// [message], and — wherever possible — an actionable [correction]. Errors
/// emitted by the toolchain also carry a stable [code] (`E####`) that indexes
/// into `docs/errors/`.
class CompileDiagnostic {
  /// Creates a diagnostic.
  const CompileDiagnostic({
    required this.severity,
    required this.message,
    required this.path,
    required this.line,
    required this.column,
    this.code,
    this.correction,
  });

  /// Whether this diagnostic is fatal.
  final DiagnosticSeverity severity;

  /// The human-readable problem statement.
  final String message;

  /// The source file path.
  final String path;

  /// The 1-based line number.
  final int line;

  /// The 1-based column number.
  final int column;

  /// The stable error code (`E####`), if this is a toolchain-emitted error.
  final String? code;

  /// An actionable suggestion for fixing the problem, if one applies.
  final String? correction;

  /// Whether this diagnostic is an [DiagnosticSeverity.error].
  bool get isError => severity == DiagnosticSeverity.error;

  @override
  String toString() {
    final tag = severity == DiagnosticSeverity.error ? 'error' : 'warning';
    final codeStr = code == null ? '' : ' [$code]';
    final fix = correction == null ? '' : '\n  correction: $correction';
    return '$path:$line:$column: $tag$codeStr: $message$fix';
  }
}

/// Thrown when a caller requests a module from a failed compilation.
class CompileException implements Exception {
  /// Creates an exception carrying the failing [diagnostics].
  CompileException(this.diagnostics);

  /// The diagnostics from the failed compilation (at least one is an error).
  final List<CompileDiagnostic> diagnostics;

  /// The error diagnostics only.
  Iterable<CompileDiagnostic> get errors => diagnostics.where((d) => d.isError);

  @override
  String toString() =>
      'CompileException:\n${errors.map((d) => '  $d').join('\n')}';
}
