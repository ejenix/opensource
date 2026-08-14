// Copyright (c) Ejenix authors. MIT license.

/// The base type for faults raised by the interpreter itself — sandbox-limit
/// violations, arity mismatches, non-callable targets, and arithmetic errors
/// such as integer division by zero.
///
/// These are distinct from exceptions thrown by the *interpreted program*,
/// which surface as [InterpreterUncaughtException] when they escape the entry
/// point. Each fault carries the bytecode program counter and function name at
/// the point of failure for debugging (brief §6.3).
class InterpreterException implements Exception {
  /// Creates an interpreter fault with an optional [pc]/[functionName] site.
  InterpreterException(this.message, {this.pc, this.functionName});

  /// A human-readable description of the fault.
  final String message;

  /// The bytecode program counter (word offset) at the fault, if known.
  final int? pc;

  /// The name of the function executing at the fault, if known.
  final String? functionName;

  @override
  String toString() {
    final site = pc == null ? '' : ' at ${functionName ?? '<fn>'}+$pc';
    return 'InterpreterException: $message$site';
  }
}

/// Wraps an exception thrown by the interpreted program that was not caught
/// within bytecode and escaped the entry point.
///
/// Once the compiler attaches source debug information, [pc] resolves to a
/// `file:line:column`; until then the bytecode [pc] is the anchor.
class InterpreterUncaughtException extends InterpreterException {
  /// Wraps [thrown], the guest value that propagated out.
  InterpreterUncaughtException(this.thrown, {super.pc, super.functionName})
    : super('uncaught exception: $thrown');

  /// The value the interpreted program threw.
  final Object? thrown;
}

/// The patch ran longer than its instruction budget and was stopped.
///
/// A hang is the one patch failure a crash-loop rollback cannot see: the UI
/// thread never returns, so nothing crashes, nothing is recorded, and the
/// device re-runs the same patch on the next launch. The budget converts that
/// unrecoverable state into an ordinary, catchable failure.
///
/// Deterministic by construction — the interpreter counts *instructions*, not
/// time, so a patch that exceeds the budget for a given input exceeds it on
/// every device for that input. That is why hosts treat it as permanent and
/// roll back rather than retrying: a retry would re-run the same loop.
///
/// Like every [InterpreterException] it propagates past interpreted `catch`,
/// so a patch cannot swallow its own budget and continue looping.
class StepLimitExceededException extends InterpreterException {
  /// Records the [limit] that was exceeded.
  StepLimitExceededException(this.limit, {super.pc, super.functionName})
    : super('step limit exceeded ($limit)');

  /// The instruction budget in force for the invocation that overran.
  final int limit;
}

/// A host capability was asked to do unbounded work and refused.
///
/// The instruction budget cannot see this: `'x' * 1000000000` and
/// `infiniteGenerator().toList()` are each a *single* bytecode instruction that
/// hands control to native Dart, which the interpreter cannot preempt. One step
/// charged, the UI thread gone. So the capabilities that can allocate or
/// consume without bound carry their own ceiling.
///
/// This covers only the built-ins listed in [HostRegistry.standard]. A
/// capability an app registers itself is outside the sandbox's reach — see
/// `docs/production.md`.
class HostBudgetExceededException extends InterpreterException {
  /// Records the [capability] that refused and the [limit] it enforces.
  HostBudgetExceededException(
    this.capability,
    this.limit, {
    super.pc,
    super.functionName,
  }) : super("host capability '$capability' exceeded its limit ($limit)");

  /// The capability name, e.g. `String *`.
  final String capability;

  /// The ceiling that was exceeded.
  final int limit;
}

/// The patch called a host capability this build does not provide.
///
/// Distinct from every other fault because it is a *deployment* fact, not a bug
/// in the patch: the capability was added to the app after this binary shipped,
/// so the patch can never run here no matter how many times it is retried. A
/// host that can fall back to a previous patch should do so on this and only
/// this — other faults may be transient (a service not ready, a null from a
/// callback) and rolling back on those would discard a working patch.
///
/// Covers both halves of the allow-list: `global` for an `invokeStatic` target
/// (`App.blogs`), `method` for a selector on a receiver kind
/// (`snapshot.hasData`).
class MissingHostCapabilityException extends InterpreterException {
  MissingHostCapabilityException.global(
    this.selector, {
    super.pc,
    super.functionName,
  }) : receiverKind = null,
       super("no host global '$selector'");

  MissingHostCapabilityException.method(
    this.selector,
    this.receiverKind, {
    super.pc,
    super.functionName,
  }) : super("no host method '$selector' on $receiverKind");

  /// The capability name the patch asked for.
  final String selector;

  /// The receiver's runtime kind for a method miss; null for a global.
  final String? receiverKind;
}
