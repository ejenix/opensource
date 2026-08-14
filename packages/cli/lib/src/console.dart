// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';

/// Console output for the CLI: honors `--json`, `--verbose`, and `--color`.
///
/// In JSON mode, only the final `emitJson` payload is written to stdout so the
/// output is machine-parseable; human messages are suppressed. Sinks are
/// injectable so command output can be captured in tests.
class Console {
  Console({
    required this.out,
    required this.err,
    this.useColor = false,
    this.json = false,
    this.verbose = false,
  });

  final StringSink out;
  final StringSink err;
  final bool useColor;
  final bool json;
  final bool verbose;

  /// A normal human-facing line (suppressed in JSON mode).
  void info(String message) {
    if (!json) out.writeln(message);
  }

  /// A success line (suppressed in JSON mode).
  void success(String message) {
    if (!json) out.writeln('${_c('32', '✓')} $message');
  }

  /// A diagnostic line, always to stderr.
  void warn(String message) {
    err.writeln('${_c('33', 'warning:')} $message');
  }

  /// An error line, always to stderr.
  void error(String message) {
    err.writeln('${_c('31', 'error:')} $message');
  }

  /// A verbose trace line to stderr (only with `--verbose`, never in JSON mode).
  void trace(String message) {
    if (verbose && !json) err.writeln(_c('90', '· $message'));
  }

  /// Emits the machine-readable result. In JSON mode it is pretty-printed to
  /// stdout; otherwise it is ignored (human lines carry the information).
  void emitJson(Object? data) {
    if (json) out.writeln(const JsonEncoder.withIndent('  ').convert(data));
  }

  String _c(String code, String text) =>
      useColor ? '\x1B[${code}m$text\x1B[0m' : text;
}
