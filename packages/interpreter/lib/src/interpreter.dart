// Copyright (c) Ejenix authors. MIT license.

import 'dart:async';
import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart';

import 'errors.dart';
import 'host_api.dart';
import 'profile.dart';

/// A runtime instance of a compiled class: which class it is (an index into
/// `Module.classes`) and its field slots. Created by `alloc`, mutated by
/// `store.field`, and dispatched on by `invoke.dyn`.
class InterpInstance {
  InterpInstance(this.classIndex, int fieldCount)
    : fields = List<Object?>.filled(fieldCount, null);

  final int classIndex;
  final List<Object?> fields;
}

/// The unique "absent argument" sentinel. A call site loads it into the slot of
/// an omitted optional or named parameter (`load.undef`); the callee's prologue
/// replaces any slot still equal to it with that parameter's default. It is
/// distinct from `null`, which is a legitimate argument value, and is never
/// reachable from interpreted Dart source.
const Object absentArgument = _Absent();

class _Absent {
  const _Absent();
  @override
  String toString() => '<absent>';
}

/// A heap-allocated box for a captured variable. A local or parameter that a
/// nested closure captures is stored in a [Cell] rather than a bare register,
/// so writes from either the enclosing scope or the closure are seen by both —
/// Dart's capture-by-reference semantics. Created by `cell.new`, read by
/// `cell.get`, written by `cell.set`.
class Cell {
  Cell(this.value);
  Object? value;
}

/// A closure value: a function prototype paired with the [Cell]s it captured
/// from its defining environment. A bare [FunctionProto] (from `load.func`) has
/// no captured state; an [InterpClosure] carries its upvalues so the same body
/// can run against different captured environments.
class InterpClosure {
  InterpClosure(this.proto, this.upvalues);
  final FunctionProto proto;
  final List<Cell> upvalues;
}

/// A per-call-site inline cache for dynamic dispatch: monomorphic fast path,
/// polymorphic up to four shapes, then megamorphic (Deutsch-Schiffman, 1984).
class _CallSiteCache {
  Type? _monoType;
  HostMethod? _monoMethod;
  Map<Type, HostMethod>? _poly;
  bool megamorphic = false;
}

/// One activation of a function: its register file, resume point, and the
/// caller register that receives its return value.
class _Frame {
  _Frame(this.proto, {this.closure})
    : registers = List<Object?>.filled(proto.registerCount, null);

  final FunctionProto proto;
  final List<Object?> registers;

  /// The closure whose body this frame runs, or `null` for a top-level or
  /// method activation. `upval.get` reads its captured cells.
  final InterpClosure? closure;

  /// Resume program counter, saved across a nested call.
  int pc = 0;

  /// The register in the *caller's* frame that receives this frame's result.
  int resultRegister = 0;

  /// An exception the async driver must deliver when this frame resumes: set
  /// when an awaited future completes with an error, consumed at the top of the
  /// dispatch loop so `try`/`catch` around the `await` can handle it. `null`
  /// means no pending error (a caught Dart error is never `null`).
  Object? pendingError;
}

/// Thrown by the `await` opcode to suspend an `async` function: it carries the
/// [future] to await, the [register] that receives the result, and the [frame]
/// to resume. Caught only by [Interpreter._callAsync], never by interpreted
/// code. Not an [Exception] — it is control flow, not an error.
class _AwaitSignal {
  _AwaitSignal(this.future, this.register, this.frame);
  final Future<Object?> future;
  final int register;
  final _Frame frame;
}

/// Thrown by the `yield` opcode to suspend a generator, carrying the yielded
/// [value]. Caught by the generator driver, never by interpreted code.
class _YieldSignal {
  _YieldSignal(this.value);
  final Object? value;
}

/// The sentinel a generator driver returns when the body has run to completion
/// (a `ret`), distinguishing "no more elements" from a yielded `null`.
const Object _generatorDone = _GeneratorDone();

class _GeneratorDone {
  const _GeneratorDone();
}

/// The lazy `Iterable` a `sync*` generator returns. Each `iterator` starts a
/// fresh activation, so the generator can be iterated more than once; the
/// iterator drives the body one `yield` at a time.
class _SyncStarIterable extends Iterable<Object?> {
  _SyncStarIterable(this._interp, this._proto, this._args, this._closure);
  final Interpreter _interp;
  final FunctionProto _proto;
  final List<Object?> _args;
  final InterpClosure? _closure;

  @override
  Iterator<Object?> get iterator {
    final root = _Frame(_proto, closure: _closure);
    for (var i = 0; i < _args.length; i++) {
      root.registers[i] = _args[i];
    }
    return _SyncStarIterator(_interp, <_Frame>[root]);
  }
}

class _SyncStarIterator implements Iterator<Object?> {
  _SyncStarIterator(this._interp, this._stack);
  final Interpreter _interp;
  final List<_Frame> _stack;
  Object? _current;
  bool _done = false;

  @override
  Object? get current => _current;

  @override
  bool moveNext() {
    if (_done) return false;
    final result = _interp._driveSyncStar(_stack);
    if (identical(result, _generatorDone)) {
      _done = true;
      _current = null;
      return false;
    }
    _current = result;
    return true;
  }
}

/// Executes a compiled [Module].
///
/// The interpreter is register-based and dispatches through a dense `switch`.
/// Dart exposes no computed-goto, so this is the "jump-table fallback" of the
/// brief's threaded-dispatch requirement (§6.3): the AOT compiler lowers a
/// dense integer switch to an indirect-branch jump table — the same control
/// structure token-threaded interpreters use for the speedups measured by Ertl
/// & Gregg (2003). Small integers ride the Dart VM's native tagged (Smi)
/// representation, so the brief's small-int specialization is provided by the
/// host without a manual boxing layer that would only slow Dart down.
///
/// The call stack is explicit rather than using Dart recursion, so deep
/// bytecode recursion is bounded by [maxCallDepth] (a typed fault, not a native
/// stack overflow) and so a per-run [stepLimit] can bound CPU.
class Interpreter {
  /// Creates an interpreter over [module].
  ///
  /// [maxCallDepth] bounds bytecode recursion depth. [stepLimit], when set,
  /// bounds the number of instructions a single [run]/[callFunction] may
  /// execute. [profile], when set, tallies executed opcodes.
  Interpreter(
    this.module, {
    this.maxCallDepth = 1024,
    this.stepLimit,
    this.profile,
    HostRegistry? hostRegistry,
  }) : hostRegistry = hostRegistry ?? HostRegistry.standard();

  /// The module being executed.
  final Module module;

  /// Maximum bytecode call-stack depth before a fault.
  final int maxCallDepth;

  /// Optional instruction budget per top-level invocation.
  final int? stepLimit;

  /// Instructions charged to the invocation in flight.
  ///
  /// Deliberately NOT local to `_dispatch`: an `async` body re-enters dispatch
  /// on every `await` resume, so a per-dispatch counter would restart at zero
  /// each time and `while (true) { await x; }` would run forever under any
  /// budget. The counter is reset at a *logical* invocation boundary
  /// ([_beginInvocation]) and spans every resume within it.
  int _steps = 0;

  /// Optional opcode profiler.
  final OpProfile? profile;

  /// The host-API allow-list backing dynamic dispatch to built-in types.
  final HostRegistry hostRegistry;

  /// Per-call-site inline caches, indexed as `invoke.dyn`'s call site.
  late final List<_CallSiteCache?> _caches = List<_CallSiteCache?>.filled(
    module.callSites.length,
    null,
  );

  /// Module-level global slots (static fields), populated by the static
  /// initializer on first invocation and read/written by `load`/`store.global`.
  late final List<Object?> _globals = List<Object?>.filled(
    module.globalCount,
    null,
  );
  bool _staticInitDone = false;

  /// Runs the static-field initializer once, before the first user invocation,
  /// so every static field holds its initialized value.
  void _ensureStaticInit() {
    if (_staticInitDone) return;
    _staticInitDone = true;
    if (module.staticInit >= 0) {
      _beginInvocation();
      _dispatch(<_Frame>[_Frame(module.functions[module.staticInit])]);
    }
  }

  /// Runs the module's entry function with [args] and returns its result.
  ///
  /// Throws [InterpreterException] if the module has no entry function.
  Object? run([List<Object?> args = const []]) {
    final entry = module.entry;
    if (entry == null) {
      throw InterpreterException('module has no entry function');
    }
    return callFunction(entry, args);
  }

  /// Invokes [fn] with [args] and returns its result.
  ///
  /// Throws [InterpreterException] on an arity mismatch or any sandbox-limit or
  /// arithmetic fault encountered during execution.
  Object? callFunction(FunctionProto fn, List<Object?> args) {
    if (fn.isAsync) {
      throw InterpreterException(
        '${fn.name} is async; call callFunctionAsync/runAsync instead',
      );
    }
    _ensureStaticInit();
    if (fn.isSyncStar || fn.isAsyncStar) {
      // A generator returns its lazy sequence without running the body.
      return _makeGenerator(fn, args);
    }
    if (args.length != fn.paramCount) {
      throw InterpreterException(
        'arity mismatch: ${fn.name} expects ${fn.paramCount} argument(s), '
        'got ${args.length}',
      );
    }
    final root = _Frame(fn);
    for (var i = 0; i < args.length; i++) {
      root.registers[i] = args[i];
    }
    _beginInvocation();
    return _dispatch(<_Frame>[root]);
  }

  /// Runs the module's entry function, awaiting it if it is `async`.
  ///
  /// Works for both sync and async entry points; a sync entry completes its
  /// future synchronously. Throws [InterpreterException] if there is no entry.
  Future<Object?> runAsync([List<Object?> args = const []]) {
    final entry = module.entry;
    if (entry == null) {
      throw InterpreterException('module has no entry function');
    }
    return callFunctionAsync(entry, args);
  }

  /// Invokes a possibly-`async` [fn], returning a future for its result.
  Future<Object?> callFunctionAsync(FunctionProto fn, List<Object?> args) {
    if (!fn.isAsync) {
      // A sync function still returns synchronously; wrap its value.
      return Future<Object?>.value(callFunction(fn, args));
    }
    _ensureStaticInit();
    // The host boundary: one budget for this call and every resume and nested
    // interpreted async call beneath it.
    _beginInvocation();
    return _callAsync(fn, args);
  }

  /// Drives an `async` function: runs it synchronously until it awaits an
  /// unresolved future, then suspends on the host event loop and resumes from
  /// the saved frame when the future completes. The interpreter's own dispatch
  /// loop is reused for the synchronous segments between awaits.
  Future<Object?> _callAsync(
    FunctionProto proto,
    List<Object?> args, {
    InterpClosure? closure,
  }) async {
    if (args.length != proto.paramCount) {
      throw InterpreterException(
        'arity mismatch: ${proto.name} expects ${proto.paramCount} '
        'argument(s), got ${args.length}',
      );
    }
    final root = _Frame(proto, closure: closure);
    for (var i = 0; i < args.length; i++) {
      root.registers[i] = args[i];
    }
    final stack = <_Frame>[root];
    // No _beginInvocation() here. This method drives the host-entered call AND
    // every nested interpreted `await f()` (see the _callAsync sites inside
    // _dispatch), so resetting here would hand each nested call a fresh budget
    // and `while (true) { await tick(); }` would run forever — which is exactly
    // what it did until this was moved to callFunctionAsync.
    while (true) {
      try {
        return _dispatch(stack);
      } on _AwaitSignal catch (sig) {
        try {
          sig.frame.registers[sig.register] = await sig.future;
        } catch (error) {
          // The awaited future failed: hand the error to the frame so a guest
          // `try`/`catch` around the `await` can catch it on resume. Unhandled,
          // it re-escapes _dispatch and fails this async function's future.
          sig.frame.pendingError = error;
        }
        // Loop: re-enter _dispatch, which resumes from the saved frame pc.
      }
    }
  }

  /// Builds the value a generator call returns without running the body: a lazy
  /// [Iterable] for `sync*`, or a `Stream` over it for `async*`.
  Object? _makeGenerator(
    FunctionProto proto,
    List<Object?> args, {
    InterpClosure? closure,
  }) {
    if (args.length != proto.paramCount) {
      throw InterpreterException(
        'arity mismatch: ${proto.name} expects ${proto.paramCount} '
        'argument(s), got ${args.length}',
      );
    }
    if (proto.isAsyncStar) return _makeAsyncStar(proto, args, closure);
    return _SyncStarIterable(this, proto, args, closure);
  }

  /// Builds the `Stream` an `async*` generator returns. On first listen, an
  /// async driver runs the body, adding each `yield` to the stream and awaiting
  /// each `await` before resuming — so an `async*` may both yield and await.
  Stream<Object?> _makeAsyncStar(
    FunctionProto proto,
    List<Object?> args,
    InterpClosure? closure,
  ) {
    late final StreamController<Object?> controller;
    controller = StreamController<Object?>(
      onListen: () {
        final root = _Frame(proto, closure: closure);
        for (var i = 0; i < args.length; i++) {
          root.registers[i] = args[i];
        }
        unawaited(_runAsyncStar(<_Frame>[root], controller));
      },
    );
    return controller.stream;
  }

  /// Drives an `async*` generator: resumes `_dispatch`, adding each `yield` to
  /// [controller], awaiting each `await`, and closing on completion or error.
  Future<void> _runAsyncStar(
    List<_Frame> stack,
    StreamController<Object?> controller,
  ) async {
    while (true) {
      try {
        _dispatch(stack);
        await controller.close();
        return;
      } on _YieldSignal catch (sig) {
        controller.add(sig.value);
      } on _AwaitSignal catch (sig) {
        try {
          sig.frame.registers[sig.register] = await sig.future;
        } catch (error) {
          sig.frame.pendingError = error;
        }
      } catch (error) {
        controller.addError(error);
        await controller.close();
        return;
      }
    }
  }

  /// Drives a suspended generator until its next `yield` (returning the value)
  /// or its completion (returning [_generatorDone]). The frame [stack] persists
  /// across calls, so iteration resumes exactly where it left off.
  Object? _driveSyncStar(List<_Frame> stack) {
    try {
      _dispatch(stack);
      return _generatorDone;
    } on _YieldSignal catch (sig) {
      return sig.value;
    }
  }

  /// Starts charging a fresh invocation against [stepLimit].
  ///
  /// Called where the *host* enters interpreted code — an entry function, a
  /// callback, one turn of a generator — and never on an internal resume.
  /// A generator is driven once per `moveNext()`, and each turn is a separate
  /// host-initiated entry, so it gets its own budget; otherwise a legitimately
  /// long sequence would eventually exhaust one shared budget and be killed.
  void _beginInvocation() => _steps = 0;

  Object? _dispatch(List<_Frame> stack) {
    final constants = module.constants;
    final functions = module.functions;
    final limit = stepLimit;
    final prof = profile;

    var frame = stack.last;
    Uint32List code = frame.proto.code;
    var regs = frame.registers;
    var pc =
        frame.pc; // 0 for a fresh frame; the saved point on an async resume

    while (true) {
      // A failed `await` leaves an error for the resuming frame; deliver it as
      // a throw at the await site before executing any further instruction.
      final pending = frame.pendingError;
      if (pending != null) {
        frame.pendingError = null;
        final thrown = pending is InterpreterUncaughtException
            ? pending.thrown
            : pending;
        final landing = _unwind(stack, frame, frame.pc - 1, thrown);
        if (landing == null) throw pending;
        frame = landing.frame;
        code = frame.proto.code;
        regs = frame.registers;
        pc = landing.pc;
        continue;
      }

      if (limit != null && ++_steps > limit) {
        throw StepLimitExceededException(
          limit,
          pc: pc,
          functionName: frame.proto.name,
        );
      }

      final opPc = pc;
      var ins = Instruction(code[pc]);
      pc++;
      var pfxHigh = 0;
      if (ins.op == Op.pfx) {
        pfxHigh = ins.ax;
        ins = Instruction(code[pc]);
        pc++;
      }
      if (prof != null) prof.record(ins.op);

      try {
        switch (ins.op) {
          // --- Constants and moves ---
          case Op.loadConst:
            regs[ins.a] = constants[(pfxHigh << 16) | ins.bx];
          case Op.loadNull:
            regs[ins.a] = null;
          case Op.loadTrue:
            regs[ins.a] = true;
          case Op.loadFalse:
            regs[ins.a] = false;
          case Op.loadInt:
            regs[ins.a] = ins.sbx;
          case Op.move:
            regs[ins.a] = regs[ins.b];
          case Op.loadFunc:
            regs[ins.a] = functions[(pfxHigh << 16) | ins.bx];
          case Op.loadUndef:
            regs[ins.a] = absentArgument;

          // --- Integer arithmetic ---
          case Op.addInt:
            regs[ins.a] = (regs[ins.b] as int) + (regs[ins.c] as int);
          case Op.subInt:
            regs[ins.a] = (regs[ins.b] as int) - (regs[ins.c] as int);
          case Op.mulInt:
            regs[ins.a] = (regs[ins.b] as int) * (regs[ins.c] as int);
          case Op.divInt:
            final divisor = regs[ins.c] as int;
            if (divisor == 0) {
              throw InterpreterException(
                'integer division by zero',
                pc: opPc,
                functionName: frame.proto.name,
              );
            }
            regs[ins.a] = (regs[ins.b] as int) ~/ divisor;
          case Op.modInt:
            final divisor = regs[ins.c] as int;
            if (divisor == 0) {
              throw InterpreterException(
                'integer modulo by zero',
                pc: opPc,
                functionName: frame.proto.name,
              );
            }
            regs[ins.a] = (regs[ins.b] as int) % divisor;
          case Op.negInt:
            regs[ins.a] = -(regs[ins.b] as int);

          // --- Double arithmetic ---
          case Op.addDouble:
            regs[ins.a] = (regs[ins.b] as double) + (regs[ins.c] as double);
          case Op.subDouble:
            regs[ins.a] = (regs[ins.b] as double) - (regs[ins.c] as double);
          case Op.mulDouble:
            regs[ins.a] = (regs[ins.b] as double) * (regs[ins.c] as double);
          case Op.divDouble:
            regs[ins.a] = (regs[ins.b] as double) / (regs[ins.c] as double);
          case Op.modDouble:
            regs[ins.a] = (regs[ins.b] as double) % (regs[ins.c] as double);
          case Op.negDouble:
            regs[ins.a] = -(regs[ins.b] as double);
          case Op.i2d:
            regs[ins.a] = (regs[ins.b] as int).toDouble();

          // --- Comparison ---
          case Op.ltInt:
            regs[ins.a] = (regs[ins.b] as int) < (regs[ins.c] as int);
          case Op.leInt:
            regs[ins.a] = (regs[ins.b] as int) <= (regs[ins.c] as int);
          case Op.gtInt:
            regs[ins.a] = (regs[ins.b] as int) > (regs[ins.c] as int);
          case Op.geInt:
            regs[ins.a] = (regs[ins.b] as int) >= (regs[ins.c] as int);
          case Op.eqInt:
            regs[ins.a] = (regs[ins.b] as int) == (regs[ins.c] as int);
          case Op.neInt:
            regs[ins.a] = (regs[ins.b] as int) != (regs[ins.c] as int);
          case Op.ltDouble:
            regs[ins.a] = (regs[ins.b] as double) < (regs[ins.c] as double);
          case Op.leDouble:
            regs[ins.a] = (regs[ins.b] as double) <= (regs[ins.c] as double);
          case Op.gtDouble:
            regs[ins.a] = (regs[ins.b] as double) > (regs[ins.c] as double);
          case Op.geDouble:
            regs[ins.a] = (regs[ins.b] as double) >= (regs[ins.c] as double);
          case Op.eq:
            regs[ins.a] = regs[ins.b] == regs[ins.c];
          case Op.ne:
            regs[ins.a] = regs[ins.b] != regs[ins.c];

          // --- Logical and control flow ---
          case Op.not:
            regs[ins.a] = !(regs[ins.b] as bool);
          case Op.jmp:
            pc += ins.sax;
          case Op.jz:
            if (!(regs[ins.a] as bool)) pc += ins.sbx;
          case Op.jnz:
            if (regs[ins.a] as bool) pc += ins.sbx;

          // --- Calls and returns ---
          case Op.call:
            final callee = regs[ins.a];
            final argCount = ins.c;
            // `call` is polymorphic over callables: a bare FunctionProto (from
            // load.func) or an InterpClosure (from closure.new), which also
            // supplies the captured environment for the pushed frame.
            final FunctionProto callProto;
            final InterpClosure? callClosure;
            if (callee is FunctionProto) {
              callProto = callee;
              callClosure = null;
            } else if (callee is InterpClosure) {
              callProto = callee.proto;
              callClosure = callee;
            } else {
              throw InterpreterException(
                'call target is not callable (${callee.runtimeType})',
                pc: opPc,
                functionName: frame.proto.name,
              );
            }
            if (callProto.paramCount != argCount) {
              throw InterpreterException(
                'arity mismatch: ${callProto.name} expects '
                '${callProto.paramCount} argument(s), got $argCount',
                pc: opPc,
                functionName: frame.proto.name,
              );
            }
            if (callProto.isAsync) {
              // An async callee returns a Future immediately; it runs on the
              // event loop rather than inline on this stack.
              final base = ins.a + 1;
              final callArgs = <Object?>[
                for (var i = 0; i < argCount; i++) regs[base + i],
              ];
              regs[ins.a] = _callAsync(
                callProto,
                callArgs,
                closure: callClosure,
              );
            } else if (callProto.isSyncStar || callProto.isAsyncStar) {
              // A generator callee returns its lazy sequence without running.
              final base = ins.a + 1;
              regs[ins.a] = _makeGenerator(callProto, <Object?>[
                for (var i = 0; i < argCount; i++) regs[base + i],
              ], closure: callClosure);
            } else {
              if (stack.length >= maxCallDepth) {
                throw InterpreterException(
                  'call stack overflow (depth $maxCallDepth)',
                  pc: opPc,
                  functionName: frame.proto.name,
                );
              }
              frame.pc = pc;
              final callee_ = _Frame(callProto, closure: callClosure)
                ..resultRegister = ins.a;
              final base = ins.a + 1;
              for (var i = 0; i < argCount; i++) {
                callee_.registers[i] = regs[base + i];
              }
              stack.add(callee_);
              frame = callee_;
              code = callProto.code;
              regs = callee_.registers;
              pc = 0;
            }
          case Op.ret:
            final result = regs[ins.a];
            final finished = stack.removeLast();
            if (stack.isEmpty) return result;
            frame = stack.last;
            code = frame.proto.code;
            regs = frame.registers;
            pc = frame.pc;
            regs[finished.resultRegister] = result;
          case Op.retVoid:
            final finished = stack.removeLast();
            if (stack.isEmpty) return null;
            frame = stack.last;
            code = frame.proto.code;
            regs = frame.registers;
            pc = frame.pc;
            regs[finished.resultRegister] = null;

          // --- Dynamic dispatch, objects, and collections ---
          case Op.invokeDyn:
            final siteIndex = (pfxHigh << 16) | ins.bx;
            final site = module.callSites[siteIndex];
            final base = ins.a;
            final receiver = regs[base];
            if (receiver is InterpInstance) {
              final descriptor = module.classes[receiver.classIndex];
              final methodIndex = descriptor.methods[site.selector];
              if (methodIndex != null) {
                // Interpreted method: push a frame with `this` in R[0].
                final callee = functions[methodIndex];
                if (callee.isAsync) {
                  // An async method returns a Future immediately.
                  regs[base] = _callAsync(callee, <Object?>[
                    receiver,
                    for (var i = 0; i < site.argCount; i++) regs[base + 1 + i],
                  ]);
                } else if (callee.isSyncStar || callee.isAsyncStar) {
                  // A generator method returns its lazy sequence.
                  regs[base] = _makeGenerator(callee, <Object?>[
                    receiver,
                    for (var i = 0; i < site.argCount; i++) regs[base + 1 + i],
                  ]);
                } else {
                  if (stack.length >= maxCallDepth) {
                    throw InterpreterException(
                      'call stack overflow (depth $maxCallDepth)',
                      pc: opPc,
                      functionName: frame.proto.name,
                    );
                  }
                  frame.pc = pc;
                  final calleeFrame = _Frame(callee)..resultRegister = base;
                  calleeFrame.registers[0] = receiver;
                  for (var i = 0; i < site.argCount; i++) {
                    calleeFrame.registers[1 + i] = regs[base + 1 + i];
                  }
                  stack.add(calleeFrame);
                  frame = calleeFrame;
                  code = callee.code;
                  regs = calleeFrame.registers;
                  pc = 0;
                }
              } else {
                // Dynamic field getter fallback.
                final slot = descriptor.fields[site.selector];
                if (slot != null && site.argCount == 0) {
                  regs[base] = receiver.fields[slot];
                } else {
                  // A selector the class does not declare falls back to the host
                  // `Object` members (`==`, `hashCode`, `toString`,
                  // `runtimeType`) — so an instance without an `operator ==`
                  // override compares by identity, per Dart.
                  final method = hostRegistry.resolve(receiver, site.selector);
                  if (method == null) {
                    throw InterpreterException(
                      "no method '${site.selector}' on class ${descriptor.name}",
                      pc: opPc,
                      functionName: frame.proto.name,
                    );
                  }
                  regs[base] = method(receiver, [
                    for (var i = 0; i < site.argCount; i++) regs[base + 1 + i],
                  ]);
                }
              }
            } else {
              final args = <Object?>[
                for (var i = 0; i < site.argCount; i++) regs[base + 1 + i],
              ];
              regs[base] = _invokeHost(
                receiver,
                site.selector,
                args,
                siteIndex,
                opPc,
                frame.proto.name,
              );
            }
          case Op.alloc:
            final classIndex = (pfxHigh << 16) | ins.bx;
            regs[ins.a] = InterpInstance(
              classIndex,
              module.classes[classIndex].fieldCount,
            );
          case Op.loadField:
            regs[ins.a] = (regs[ins.b] as InterpInstance).fields[ins.c];
          case Op.storeField:
            (regs[ins.a] as InterpInstance).fields[ins.b] = regs[ins.c];
          case Op.loadGlobal:
            regs[ins.a] = _globals[(pfxHigh << 16) | ins.bx];
          case Op.storeGlobal:
            _globals[(pfxHigh << 16) | ins.bx] = regs[ins.a];
          case Op.invokeStatic:
            final site = module.callSites[(pfxHigh << 16) | ins.bx];
            final base = ins.a;
            final global = hostRegistry.resolveGlobal(site.selector);
            if (global == null) {
              throw MissingHostCapabilityException.global(
                site.selector,
                pc: opPc,
                functionName: frame.proto.name,
              );
            }
            final args = <Object?>[
              for (var i = 0; i < site.argCount; i++) regs[base + i],
            ];
            regs[base] = global(null, args);
          case Op.listNew:
            regs[ins.a] = <Object?>[];
          case Op.mapNew:
            regs[ins.a] = <Object?, Object?>{};
          case Op.setNew:
            regs[ins.a] = <Object?>{};
          case Op.recordNew:
            final shape = constants[(pfxHigh << 16) | ins.bx] as String;
            final sep = shape.indexOf(';');
            final posCount = int.parse(
              sep < 0 ? shape : shape.substring(0, sep),
            );
            final base = ins.a;
            final positional = <Object?>[
              for (var i = 0; i < posCount; i++) regs[base + i],
            ];
            final named = <String, Object?>{};
            if (sep >= 0) {
              final keys = shape.substring(sep + 1).split(',');
              for (var i = 0; i < keys.length; i++) {
                named[keys[i]] = regs[base + posCount + i];
              }
            }
            regs[base] = InterpRecord(positional, named);
          case Op.recordGet:
            final field = constants[(pfxHigh << 16) | ins.bx] as String;
            final record = regs[ins.a] as InterpRecord;
            if (field.startsWith(r'$')) {
              regs[ins.a] =
                  record.positional[int.parse(field.substring(1)) - 1];
            } else {
              regs[ins.a] = record.named[field];
            }

          // --- Closures and captured variables ---
          case Op.closureNew:
            final proto = functions[(pfxHigh << 16) | ins.bx];
            final captures = proto.captures;
            final upvalues = List<Cell>.generate(
              captures.length,
              (i) => regs[captures[i]] as Cell,
              growable: false,
            );
            regs[ins.a] = InterpClosure(proto, upvalues);
          case Op.upvalGet:
            regs[ins.a] = frame.closure!.upvalues[(pfxHigh << 16) | ins.bx];
          case Op.cellNew:
            regs[ins.a] = Cell(regs[ins.a]);
          case Op.cellGet:
            regs[ins.a] = (regs[ins.b] as Cell).value;
          case Op.cellSet:
            (regs[ins.a] as Cell).value = regs[ins.b];

          // --- Async ---
          case Op.awaitValue:
            final awaited = regs[ins.a];
            if (awaited is Future) {
              // Suspend: save the resume point (pc is already past this
              // instruction) and hand the future to the async driver.
              frame.pc = pc;
              throw _AwaitSignal(awaited, ins.a, frame);
            }
          // Awaiting a non-future yields the value unchanged; fall through.

          // --- Type tests ---
          case Op.isType:
            regs[ins.a] = _isType(
              regs[ins.a],
              constants[(pfxHigh << 16) | ins.bx] as String,
            );
          case Op.asType:
            final spec = constants[(pfxHigh << 16) | ins.bx] as String;
            if (!_isType(regs[ins.a], spec)) {
              throw InterpreterException(
                'failed cast: ${regs[ins.a].runtimeType} is not $spec',
                pc: opPc,
                functionName: frame.proto.name,
              );
            }

          case Op.throwValue:
            // Guest `throw`: raise the value; the catch below unwinds to the
            // nearest enclosing handler, or it escapes as an uncaught exception.
            throw InterpreterUncaughtException(
              regs[ins.a],
              pc: opPc,
              functionName: frame.proto.name,
            );

          case Op.yieldValue:
            // Suspend the generator, surfacing the value to its driver. The
            // resume point (past this instruction) is saved on the frame.
            frame.pc = pc;
            throw _YieldSignal(regs[ins.a]);

          case Op.pfx:
            // A lone pfx not consumed by a following aBx instruction is
            // malformed code; the assembler never emits one.
            throw InterpreterException(
              'dangling pfx prefix',
              pc: opPc,
              functionName: frame.proto.name,
            );
        }
      } on _AwaitSignal {
        rethrow; // control flow for `await`, never guest-catchable
      } on _YieldSignal {
        rethrow; // control flow for `yield`, delivered to the generator driver
      } catch (error) {
        // Interpreter faults (sandbox limits, failed casts, dispatch errors)
        // are VM-level and propagate past guest `catch`; only guest `throw` and
        // Dart exceptions from host calls are catchable by interpreted code.
        if (error is InterpreterException &&
            error is! InterpreterUncaughtException) {
          rethrow;
        }
        final thrown = error is InterpreterUncaughtException
            ? error.thrown
            : error;
        final landing = _unwind(stack, frame, opPc, thrown);
        if (landing == null) rethrow;
        frame = landing.frame;
        code = frame.proto.code;
        regs = frame.registers;
        pc = landing.pc;
      }
    }
  }

  /// Searches for the innermost handler protecting the throw site and unwinds
  /// the stack to it. [throwingFrame] threw at [throwPc]; callers are searched
  /// at their own call sites (`pc - 1`). On a match, pops inner frames, stores
  /// [thrown] in the handler's catch register, and returns the landing frame
  /// and target pc. Returns `null` when no frame handles the throw.
  ({_Frame frame, int pc})? _unwind(
    List<_Frame> stack,
    _Frame throwingFrame,
    int throwPc,
    Object? thrown,
  ) {
    for (var i = stack.length - 1; i >= 0; i--) {
      final f = stack[i];
      final searchPc = identical(f, throwingFrame) ? throwPc : f.pc - 1;
      for (final h in f.proto.handlers) {
        if (searchPc >= h.start && searchPc < h.end) {
          while (stack.length - 1 > i) {
            stack.removeLast();
          }
          f.registers[h.catchReg] = thrown;
          return (frame: f, pc: h.target);
        }
      }
    }
    return null;
  }

  /// Resolves and invokes [selector] on [receiver] through the host-API
  /// allow-list, consulting and updating the inline cache for [siteIndex].
  Object? _invokeHost(
    Object? receiver,
    String selector,
    List<Object?> args,
    int siteIndex,
    int pc,
    String functionName,
  ) {
    final cache = _caches[siteIndex] ??= _CallSiteCache();
    final type = receiver.runtimeType;
    HostMethod? method;

    if (cache.megamorphic) {
      method = hostRegistry.resolve(receiver, selector);
    } else if (cache._monoType == type) {
      method = cache._monoMethod;
    } else if (cache._poly != null && cache._poly!.containsKey(type)) {
      method = cache._poly![type];
    } else {
      method = hostRegistry.resolve(receiver, selector);
      if (method != null) _fillCache(cache, type, method);
    }

    if (method == null) {
      throw MissingHostCapabilityException.method(
        selector,
        '${receiver.runtimeType}',
        pc: pc,
        functionName: functionName,
      );
    }
    return method(receiver, _marshalArgs(args));
  }

  /// Replaces any interpreted callable arguments — an [InterpClosure] or a bare
  /// [FunctionProto] (a top-level/static tear-off from `load.func`) — with real
  /// Dart functions so host higher-order methods (`map`, `where`, `forEach`,
  /// `sort`, …) can call back into the VM. Returns [args] unchanged when it
  /// holds no callables, so the common path allocates nothing.
  List<Object?> _marshalArgs(List<Object?> args) {
    var hasCallable = false;
    for (final a in args) {
      if (a is InterpClosure || a is FunctionProto) {
        hasCallable = true;
        break;
      }
    }
    if (!hasCallable) return args;
    return [
      for (final a in args)
        if (a is InterpClosure)
          _dartAdapter(a.proto, a)
        else if (a is FunctionProto)
          _dartAdapter(a, null)
        else
          a,
    ];
  }

  /// Wraps an interpreted callable ([proto] plus its optional capturing
  /// [closure]) in a fixed-arity Dart function that re-enters the VM. The
  /// parameter types are `Object?` so the adapter is a subtype of the function
  /// type any host method expects (contravariant parameters).
  Function _dartAdapter(FunctionProto proto, InterpClosure? closure) {
    Object? invoke(List<Object?> args) => closure != null
        ? invokeClosure(closure, args)
        : callFunction(proto, args);
    switch (proto.paramCount) {
      case 0:
        return () => invoke(const []);
      case 1:
        return (Object? a) => invoke([a]);
      case 2:
        return (Object? a, Object? b) => invoke([a, b]);
      case 3:
        return (Object? a, Object? b, Object? c) => invoke([a, b, c]);
      default:
        throw InterpreterException(
          'callables with ${proto.paramCount} parameters cannot be passed to '
          'host methods (max 3)',
        );
    }
  }

  /// Whether [value] satisfies the type named by [spec] — a base type name with
  /// an optional trailing `?` for nullability. Covers `dart:core` types and
  /// user classes (by walking the class table); other host types fall back to a
  /// runtime-type-name match. Generics are erased (`List<int>` → `List`).
  bool _isType(Object? value, String spec) {
    final nullable = spec.endsWith('?');
    final name = nullable ? spec.substring(0, spec.length - 1) : spec;
    if (value == null) return nullable || name == 'Null';
    switch (name) {
      case 'Object':
      case 'dynamic':
        return true;
      case 'int':
        return value is int;
      case 'double':
        return value is double;
      case 'num':
        return value is num;
      case 'String':
        return value is String;
      case 'bool':
        return value is bool;
      case 'List':
        return value is List;
      case 'Map':
        return value is Map;
      case 'Set':
        return value is Set;
      case 'Iterable':
        return value is Iterable;
      case 'Function':
        return value is Function ||
            value is InterpClosure ||
            value is FunctionProto;
      case 'Null':
        return false; // value is non-null here
      // Exception/error hierarchy: host values are real Dart objects, so `is`
      // is exact; a guest-thrown [InterpInstance] matches none of these (it is
      // handled by the user-class walk below or a catch-all clause).
      case 'Exception':
        return value is Exception;
      case 'Error':
        return value is Error;
      case 'FormatException':
        return value is FormatException;
      case 'StateError':
        return value is StateError;
      case 'ArgumentError':
        return value is ArgumentError;
      case 'RangeError':
        return value is RangeError;
      case 'IndexError':
        return value is IndexError;
      case 'TypeError':
        return value is TypeError;
      case 'UnsupportedError':
        return value is UnsupportedError;
      case 'UnimplementedError':
        return value is UnimplementedError;
      case 'ConcurrentModificationError':
        return value is ConcurrentModificationError;
      default:
        if (value is InterpInstance) {
          var idx = value.classIndex;
          while (idx >= 0) {
            final d = module.classes[idx];
            if (d.name == name) return true;
            idx = d.superIndex;
          }
          return false;
        }
        // A bridged host type (e.g. a Flutter widget): best-effort name match.
        return value.runtimeType.toString() == name;
    }
  }

  /// Invokes [closure] with [args] on a fresh activation, returning its result.
  /// Used both by the `call` opcode's re-entrant callers and by [_dartAdapter]
  /// when a host method calls back into interpreted code.
  Object? invokeClosure(InterpClosure closure, List<Object?> args) {
    final proto = closure.proto;
    if (args.length != proto.paramCount) {
      throw InterpreterException(
        'arity mismatch: closure ${proto.name} expects ${proto.paramCount} '
        'argument(s), got ${args.length}',
      );
    }
    if (proto.isSyncStar || proto.isAsyncStar) {
      return _makeGenerator(proto, args, closure: closure);
    }
    final root = _Frame(proto, closure: closure);
    for (var i = 0; i < args.length; i++) {
      root.registers[i] = args[i];
    }
    _beginInvocation();
    return _dispatch(<_Frame>[root]);
  }

  void _fillCache(_CallSiteCache cache, Type type, HostMethod method) {
    if (cache._monoType == null) {
      cache._monoType = type;
      cache._monoMethod = method;
    } else {
      final poly = cache._poly ??= {cache._monoType!: cache._monoMethod!};
      poly[type] = method;
      if (poly.length > 4) cache.megamorphic = true;
    }
  }
}
