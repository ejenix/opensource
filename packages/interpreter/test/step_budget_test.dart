// Copyright (c) Ejenix authors. MIT license.

/// The instruction budget must bound a *logical invocation*, not one segment
/// of one.
///
/// The first version of this guard kept its counter local to `_dispatch`. That
/// bounded a synchronous loop correctly and looked well tested — but an `async`
/// body re-enters `_dispatch` once per `await` resume, so the counter restarted
/// at zero every time and `while (true) { await x; }` ran forever under any
/// budget. The counter now lives on the interpreter and is reset only where the
/// host enters interpreted code.
///
/// The generator cases pin the opposite risk: each `moveNext()` is a separate
/// host-initiated entry and must get a fresh budget, or a legitimately long
/// lazy sequence would exhaust one shared budget and be killed mid-iteration.
library;

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// A budget in the range a real host uses, for the "still works" cases.
const kDefaultProbeBudget = 5000000;

/// `f() async { while (true) { await tick(); } }`
///
/// The shape the per-dispatch counter could not see: every `await` handed
/// control back to the driver, which re-entered dispatch with a clean slate.
Module _asyncSpinsForever() {
  final b = BytecodeBuilder();
  final top = Label();
  b.bind(top);
  b.emitABx(Op.invokeStatic, 0, 0); // R0 = tick()  → a completed Future
  b.emitA(Op.awaitValue, 0); // await R0
  b.emitJmp(top);
  return Module(
    constants: ConstantPool(),
    functions: [
      b.toProto(name: 'f', paramCount: 0, registerCount: 1, isAsync: true),
    ],
    callSites: const [CallSite(selector: 'tick', argCount: 0)],
  );
}

/// `tick() async => 1;  f() async { while (true) { await tick(); } }`
///
/// The case a host-function test cannot reach. `await hostFn()` suspends on a
/// Future the host produced; `await tick()` invokes another *interpreted* async
/// function, which enters the async driver a second time. The first fix reset
/// the budget inside that driver, so every nested call started from zero and
/// the loop was still unbounded — passing the host-function test the whole
/// time. Only a compiled-source probe caught it.
Module _asyncCallsInterpretedAsync() {
  // f: loop { r0 = tick();  await r0 }   — tick is functions[1], interpreted.
  final f = BytecodeBuilder();
  final top = Label();
  f.bind(top);
  f.emitABx(Op.loadFunc, 0, 1);
  f.emitABC(Op.call, 0, 0, 0);
  f.emitA(Op.awaitValue, 0);
  f.emitJmp(top);

  // tick: return 1
  final tick =
      (BytecodeBuilder()
            ..emitLoadInt(0, 1)
            ..emitA(Op.ret, 0))
          .toProto(
            name: 'tick',
            paramCount: 0,
            registerCount: 1,
            isAsync: true,
          );

  return Module(
    constants: ConstantPool(),
    functions: [
      f.toProto(name: 'f', paramCount: 0, registerCount: 2, isAsync: true),
      tick,
    ],
  );
}

/// `f() { while (true) {} }` — the synchronous case, which already worked.
Module _syncSpinsForever() {
  final b = BytecodeBuilder();
  final top = Label();
  b.bind(top);
  b.emitJmp(top);
  return Module(
    constants: ConstantPool(),
    functions: [b.toProto(name: 'f', paramCount: 0, registerCount: 1)],
  );
}

/// `f() sync* { var i = 0; while (true) { yield i; } }` — an unbounded lazy
/// sequence. Legitimate: the consumer decides how much to pull.
Module _generatorYieldsForever() {
  final b = BytecodeBuilder();
  final top = Label();
  b.emitLoadInt(0, 7);
  b.bind(top);
  b.emitA(Op.yieldValue, 0);
  b.emitJmp(top);
  return Module(
    constants: ConstantPool(),
    functions: [
      b.toProto(name: 'f', paramCount: 0, registerCount: 2, isSyncStar: true),
    ],
  );
}

/// An endless lazy sequence — `toList()` on it is one instruction and an
/// unbounded native loop.
Iterable<Object?> _endless() sync* {
  var i = 0;
  while (true) {
    yield i++;
  }
}

HostRegistry _withTick() =>
    HostRegistry.standard()
      ..registerGlobal('tick', (_, _) => Future<Object?>.value(1));

void main() {
  test('a synchronous infinite loop is stopped', () async {
    final interp = Interpreter(_syncSpinsForever(), stepLimit: 10000);
    expect(
      () => interp.callFunction(interp.module.functions.first, const []),
      throwsA(isA<StepLimitExceededException>()),
    );
  });

  test('an async loop that awaits every turn is stopped too', () async {
    // The regression this file exists for. Before the counter moved off
    // _dispatch, this test did not fail — it hung until the suite timed out.
    final interp = Interpreter(
      _asyncSpinsForever(),
      stepLimit: 10000,
      hostRegistry: _withTick(),
    );
    await expectLater(
      interp.callFunctionAsync(interp.module.functions.first, const []),
      throwsA(isA<StepLimitExceededException>()),
    );
  });

  test('a nested interpreted async call does not refresh the budget', () async {
    // The regression the host-function test could not see.
    final interp = Interpreter(_asyncCallsInterpretedAsync(), stepLimit: 10000);
    await expectLater(
      interp.callFunctionAsync(interp.module.functions.first, const []),
      throwsA(isA<StepLimitExceededException>()),
    );
  });

  test(
    'the budget spans resumes rather than restarting at each await',
    () async {
      // A budget smaller than the loop body proves accumulation across resumes:
      // if each resume reset the counter, no single segment would exceed it and
      // the call would never terminate.
      final interp = Interpreter(
        _asyncSpinsForever(),
        stepLimit: 50,
        hostRegistry: _withTick(),
      );
      await expectLater(
        interp.callFunctionAsync(interp.module.functions.first, const []),
        throwsA(
          isA<StepLimitExceededException>().having((e) => e.limit, 'limit', 50),
        ),
      );
    },
  );

  test(
    'generator turns charge the invocation budget, so draining is bounded',
    () {
      // Verified against the real compiler by a probe: `g().toList()` on an
      // endless `sync*` terminates with StepLimitExceededException rather than
      // hanging, because each `moveNext()` charges the same budget.
      //
      // An earlier version of this test asserted the opposite — that each turn
      // got a fresh budget — and passed only because 500 pulls landed a hair
      // under the limit. Accumulation is the safer semantic and the real one.
      final interp = Interpreter(_generatorYieldsForever(), stepLimit: 1000);
      final it =
          interp.callFunction(interp.module.functions.first, const [])
              as Iterable<Object?>;
      expect(
        () => it.toList(),
        throwsA(isA<StepLimitExceededException>()),
        reason: 'an endless generator must not be drainable without bound',
      );
    },
  );

  test('a modest pull from a generator stays well inside the budget', () {
    // The other half: accumulation must not make ordinary lazy iteration
    // fragile. A short pull under a realistic budget has to keep working.
    final interp = Interpreter(
      _generatorYieldsForever(),
      stepLimit: kDefaultProbeBudget,
    );
    final it =
        interp.callFunction(interp.module.functions.first, const [])
            as Iterable<Object?>;
    expect(it.take(500).toList().length, 500);
  });

  group('host capabilities carry their own ceiling', () {
    // The instruction budget cannot see native work: each of these is ONE
    // bytecode instruction that hands control to Dart and cannot be preempted.
    final host = HostRegistry.standard();

    test("'x' * huge is refused before it allocates", () {
      final repeat = host.resolve('x', '*')!;
      expect(
        () => repeat('x', [1 << 30]),
        throwsA(
          isA<HostBudgetExceededException>().having(
            (e) => e.capability,
            'capability',
            'String *',
          ),
        ),
      );
    });

    test('a normal repeat still works', () {
      expect(host.resolve('x', '*')!('ab', [3]), 'ababab');
    });

    test('toList on an endless iterable is refused, not hung', () {
      // Resolve against a lazy iterable, not a List — List carries its own
      // toList binding that never reaches the Iterable one under test.
      final endless = _endless();
      final toList = host.resolve(endless, 'toList')!;
      expect(
        () => toList(endless, const []),
        throwsA(isA<HostBudgetExceededException>()),
      );
    });

    test('toList on an ordinary lazy iterable is unaffected', () {
      final lazy = [1, 2, 3].map((e) => e * 2);
      expect(host.resolve(lazy, 'toList')!(lazy, const []), [2, 4, 6]);
    });
  });

  test('a fresh invocation is not charged for the previous one', () {
    // Without a reset at the host boundary the counter would run cumulatively
    // and the Nth callback would die for work the 1st did.
    final interp = Interpreter(_syncSpinsForever(), stepLimit: 10000);
    final fn = interp.module.functions.first;
    for (var i = 0; i < 3; i++) {
      expect(
        () => interp.callFunction(fn, const []),
        throwsA(isA<StepLimitExceededException>()),
        reason: 'invocation $i must get its own budget',
      );
    }
  });
}
