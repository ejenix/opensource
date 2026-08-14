// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

/// A protected region and where to jump when it throws. `[start, end)` is the
/// half-open range of instruction words covered; on a throw within it the
/// interpreter puts the exception in `catchReg` and jumps to `target`. Handlers
/// are tried in order, so inner (earlier) regions take precedence. `finally`
/// blocks are lowered to catch-all handlers whose target re-throws.
class ExceptionHandler {
  const ExceptionHandler({
    required this.start,
    required this.end,
    required this.target,
    required this.catchReg,
  });

  final int start;
  final int end;
  final int target;
  final int catchReg;
}

/// A compiled function: its code and the shape of the frame it runs in.
///
/// The interpreter allocates a register file of exactly [registerCount] slots
/// per activation, sized from the compiler's `regmax` metadata, so locals never
/// spill to the heap (brief §6.3). Parameters occupy the first [paramCount]
/// registers on entry; the remaining registers are locals and temporaries.
class FunctionProto {
  /// Creates a function prototype.
  ///
  /// [registerCount] must be at least [paramCount]; the assertion guards the
  /// invariant that every parameter has a home register.
  FunctionProto({
    required this.name,
    required this.paramCount,
    required this.registerCount,
    required this.code,
    this.captures = const [],
    this.isAsync = false,
    this.isSyncStar = false,
    this.isAsyncStar = false,
    this.handlers = const [],
  }) : assert(
         registerCount >= paramCount,
         'registerCount ($registerCount) < paramCount ($paramCount)',
       );

  /// The function's name, used in disassembly and stack traces.
  final String name;

  /// The number of positional parameters, placed in `R[0] .. R[paramCount-1]`.
  final int paramCount;

  /// The number of register slots this function's frame requires.
  final int registerCount;

  /// The instruction stream, one 32-bit word per encoded instruction.
  final Uint32List code;

  /// For a closure, the registers in the *defining* frame that hold the cells
  /// to capture, in upvalue order — so `closure.new` needs only this proto's
  /// index. Each entry becomes `upvalues[i]` in the resulting closure, read back
  /// with `upval.get i`. Empty for top-level and static functions, which capture
  /// nothing.
  final List<int> captures;

  /// Whether this function is `async`: it returns a `Future`, its body may
  /// `await`, and the interpreter runs it on the event loop rather than inline.
  final bool isAsync;

  /// Whether this is a `sync*` generator: calling it returns a lazy `Iterable`
  /// that drives the body one `yield` at a time (so an infinite generator is
  /// fine when consumed lazily).
  final bool isSyncStar;

  /// Whether this is an `async*` generator: calling it returns a `Stream` over
  /// the same lazily-driven body.
  final bool isAsyncStar;

  /// The exception-handler table (`try`/`catch`/`finally` regions), tried in
  /// order on a throw. Empty for functions with no protected regions.
  final List<ExceptionHandler> handlers;
}
