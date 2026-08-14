// Copyright (c) Ejenix authors. MIT license.

/// A patch that *hangs* must not be able to brick the app.
///
/// Every other patch failure is self-limiting: it throws, the frame falls back,
/// and the crash-loop counter eventually rolls the device back. A hang is the
/// exception, and the worst case in the system — the interpreted `build()`
/// never returns, so the UI thread stops, nothing crashes, no rollback is
/// triggered, and the same patch runs again on the next launch. Server-side
/// rollback cannot help: a frozen app never fetches anything.
///
/// The instruction budget is what turns that unrecoverable state into an
/// ordinary, recoverable failure. These tests hold that line.
library;

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `build() { while (true) {} }` — a bare backward jump to itself.
Module _infiniteLoop() {
  final b = BytecodeBuilder();
  final top = Label();
  b.bind(top);
  b.emitJmp(top);
  return Module(
    constants: ConstantPool(),
    functions: [b.toProto(name: 'build', paramCount: 0, registerCount: 1)],
  );
}

/// `build() { try { while (true) {} } catch (_) { return 1; } }`
///
/// The adversarial case: a patch that wraps its own loop in a handler. If the
/// budget were an ordinary guest-catchable throw, this would swallow it and
/// spin forever — the guard would be decorative.
Module _loopInsideGuestCatch() {
  final b = BytecodeBuilder();
  final start = Label();
  final end = Label();
  final handler = Label();
  b.bind(start);
  final top = Label();
  b.bind(top);
  b.emitJmp(top);
  b.bind(end);
  b.bind(handler);
  b.emitLoadInt(0, 1);
  b.emitA(Op.ret, 0);
  b.addHandler(start, end, handler, 0);
  return Module(
    constants: ConstantPool(),
    functions: [b.toProto(name: 'build', paramCount: 0, registerCount: 2)],
  );
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('a hanging patch falls back instead of freezing the app', (
    tester,
  ) async {
    // If the budget were missing this test would not fail — it would hang the
    // whole suite, which is exactly what it does on a device.
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _infiniteLoop(),
        stepLimit: 50000,
        errorBuilder: (_, e) {
          captured = e;
          return const Text('native fallback');
        },
      ),
    );

    expect(find.text('native fallback'), findsOneWidget);
    expect(captured, isA<StepLimitExceededException>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('the budget is on by default, not opt-in', (tester) async {
    // The whole finding was that the guard existed and nothing turned it on.
    // A host that says nothing about limits must still be protected.
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _infiniteLoop(),
        errorBuilder: (_, e) {
          captured = e;
          return const Text('native fallback');
        },
      ),
    );

    expect(captured, isA<StepLimitExceededException>());
    expect(
      (captured! as StepLimitExceededException).limit,
      kDefaultPatchStepLimit,
    );
  });

  testWidgets('a patch cannot catch its own budget and keep looping', (
    tester,
  ) async {
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _loopInsideGuestCatch(),
        stepLimit: 50000,
        errorBuilder: (_, e) {
          captured = e;
          return const Text('native fallback');
        },
      ),
    );

    // The handler must NOT have run: had it swallowed the fault, build() would
    // have returned 1 and we would be looking at a PatchOutputException.
    expect(captured, isA<StepLimitExceededException>());
    expect(find.text('native fallback'), findsOneWidget);
  });

  test(
    'an overrun is permanent, so the host rolls back instead of retrying',
    () {
      // The budget counts instructions, not milliseconds, so the same patch
      // overruns identically on every device for the same input. Retrying would
      // re-enter the same loop; only a rollback recovers.
      expect(isUnrunnableOnThisBuild(StepLimitExceededException(1000)), isTrue);
    },
  );

  testWidgets('an ordinary patch is untouched by the default budget', (
    tester,
  ) async {
    // The guard against the guard: a limit low enough to catch loops but also
    // low enough to kill real patches would be a worse outage than the hang.
    final b = BytecodeBuilder();
    for (var i = 0; i < 200; i++) {
      b.emitLoadInt(0, i);
    }
    b.emitA(Op.loadNull, 0);
    b.emitA(Op.ret, 0);
    final module = Module(
      constants: ConstantPool(),
      functions: [b.toProto(name: 'build', paramCount: 0, registerCount: 2)],
    );

    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: module,
        errorBuilder: (_, e) {
          captured = e;
          return const Text('native fallback');
        },
      ),
    );

    expect(
      captured,
      isNot(isA<StepLimitExceededException>()),
      reason: 'a trivial build() must never hit the default budget',
    );
  });
}
