// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';

/// Collects opcode execution counts for the dev-mode profiler (brief §6.3).
///
/// Passing an [OpProfile] to the interpreter makes the dispatch loop tally
/// every executed instruction, which `interp profile` renders as a hot-opcode
/// report. It is opt-in: when no profile is supplied the loop pays nothing.
class OpProfile {
  final Map<Op, int> _counts = {};

  /// Records one execution of [op].
  void record(Op op) => _counts[op] = (_counts[op] ?? 0) + 1;

  /// The number of times [op] has executed.
  int countOf(Op op) => _counts[op] ?? 0;

  /// The total number of instructions executed.
  int get totalSteps => _counts.values.fold(0, (sum, n) => sum + n);

  /// The [limit] hottest opcodes, most-executed first.
  List<MapEntry<Op, int>> hottest([int limit = 10]) {
    final entries = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).toList();
  }

  /// Clears all recorded counts.
  void reset() => _counts.clear();
}
