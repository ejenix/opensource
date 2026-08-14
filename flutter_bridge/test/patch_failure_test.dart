// Copyright (c) Ejenix authors. MIT license.

/// A patch that cannot run must not take the screen down.
///
/// Reported from production: a patch calling `App.blogs` on a build that did
/// not register it threw `InterpreterException: no host global 'App.blogs'`
/// out of `build()`, and the user got Flutter's red error screen where the app
/// should have been. That inverts the promise the loader is built on — the
/// binary alone is always a working app.
///
/// Two failure modes are covered here, because they surface at different
/// moments: a capability the build never registered (knowable before the patch
/// runs) and a patch that throws while rendering (only knowable during).
library;

import 'dart:convert';

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `build() => App.blogs();` — one host call and nothing else.
Module _callsMissingGlobal() {
  final f =
      (BytecodeBuilder()
            ..emitABx(Op.invokeStatic, 0, 0)
            ..emitA(Op.ret, 0))
          .toProto(name: 'build', paramCount: 0, registerCount: 2);
  return Module(
    constants: ConstantPool(),
    functions: [f],
    callSites: const [CallSite(selector: 'App.blogs', argCount: 0)],
  );
}

/// `build() => null.noSuchMethodHere();` — a host *method* this build does not
/// register. The other half of the allow-list, and the drift a fleet actually
/// accumulates as the bridge grows.
Module _callsMissingHostMethod() {
  final f =
      (BytecodeBuilder()
            ..emitA(Op.loadNull, 0)
            ..emitABx(Op.invokeDyn, 0, 0)
            ..emitA(Op.ret, 0))
          .toProto(name: 'build', paramCount: 0, registerCount: 3);
  return Module(
    constants: ConstantPool(),
    functions: [f],
    callSites: const [CallSite(selector: 'noSuchMethodHere', argCount: 0)],
  );
}

/// `build() { return null + null; }` — a fault with nothing to do with the
/// allow-list, so it must NOT cost the user their patch.
Module _throwsTypeErrorDuringBuild() {
  final f =
      (BytecodeBuilder()
            ..emitA(Op.loadNull, 1)
            ..emitA(Op.loadNull, 2)
            ..emitABC(Op.addInt, 0, 1, 2)
            ..emitA(Op.ret, 0))
          .toProto(name: 'build', paramCount: 0, registerCount: 3);
  return Module(constants: ConstantPool(), functions: [f]);
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  group('capability manifest', _manifestTests);
  group('capability variants', _variantTests);
  group('stranding', _strandingTests);

  testWidgets('a missing capability shows the fallback, not a red screen', (
    tester,
  ) async {
    await _pump(
      tester,
      InterpretedView(
        module: _callsMissingGlobal(),
        errorBuilder: (_, _) => const Text('native fallback'),
      ),
    );

    expect(find.text('native fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the error names the capability and how to fix it', (
    tester,
  ) async {
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _callsMissingGlobal(),
        errorBuilder: (_, e) {
          captured = e;
          return const SizedBox();
        },
      ),
    );

    expect(captured, isA<MissingHostCapabilityException>());
    final error = captured! as MissingHostCapabilityException;
    expect(error.selector, 'App.blogs');
    // Named exactly, from the instruction that needed it — not inferred from a
    // scan that could be wrong about which capabilities a patch really uses.
    expect(error.toString(), contains('App.blogs'));
    // And classified as permanent, which is what licenses a rollback.
    expect(isUnrunnableOnThisBuild(error), isTrue);
  });

  testWidgets('a missing host METHOD is unrunnable too, not just a global', (
    tester,
  ) async {
    // The allow-list has two halves. A gate that only knew about globals would
    // miss `snapshot.hasData` / `controller.clear()` drift entirely.
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _callsMissingHostMethod(),
        errorBuilder: (_, e) {
          captured = e;
          return const SizedBox();
        },
      ),
    );
    expect(captured, isA<MissingHostCapabilityException>());
    expect(isUnrunnableOnThisBuild(captured!), isTrue);
  });

  testWidgets('a transient render fault is NOT treated as unrunnable', (
    tester,
  ) async {
    // Guards the rollback trigger: only a missing capability may cost the user
    // their patch. Classifying an ordinary fault as permanent would discard a
    // working patch over a one-off.
    Object? captured;
    await _pump(
      tester,
      InterpretedView(
        module: _throwsTypeErrorDuringBuild(),
        errorBuilder: (_, e) {
          captured = e;
          return const SizedBox();
        },
      ),
    );
    expect(captured, isNotNull);
    expect(captured, isNot(isA<MissingHostCapabilityException>()));
    expect(isUnrunnableOnThisBuild(captured!), isFalse);
  });

  testWidgets('a patch that throws mid-render falls back too', (tester) async {
    await _pump(
      tester,
      InterpretedView(
        module: _throwsTypeErrorDuringBuild(),
        errorBuilder: (_, _) => const Text('native fallback'),
      ),
    );

    expect(find.text('native fallback'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without an errorBuilder the failure is visible, not swallowed', (
    tester,
  ) async {
    await _pump(tester, InterpretedView(module: _callsMissingGlobal()));

    // Silently rendering nothing would be worse than a red screen: the operator
    // would see an empty screen and no signal that a patch was rejected.
    expect(find.byType(ErrorWidget), findsOneWidget);
  });
}

void _manifestTests() {
  test('the manifest covers the built-ins, not just app capabilities', () {
    // The false-positive guard for the publish gate: a manifest listing only
    // @Patchable names would reject every patch that uses Text() or Column().
    final json = jsonDecode(capabilityManifest(null)) as Map<String, Object?>;
    final globals = (json['globals']! as List).cast<String>();

    expect(globals, contains('Text'));
    expect(globals, contains('Column'));
    expect(globals, contains('setState'));
    expect(globals, equals([...globals]..sort()), reason: 'stable for diffing');
    expect((json['methods']! as List), isNotEmpty);
  });

  test('an app extension widens the manifest', () {
    final json =
        jsonDecode(
              capabilityManifest(
                (r, _) => r.registerGlobal('App.blogs', (_, _) => null),
              ),
            )
            as Map<String, Object?>;
    expect((json['globals']! as List).cast<String>(), contains('App.blogs'));
  });

  test('a patch is checkable against the manifest it was built for', () {
    // End to end, the way CI does it.
    final shipped =
        ((jsonDecode(capabilityManifest(null)) as Map)['globals']! as List)
            .cast<String>()
            .toSet();
    final needs = requiredHostGlobals(_callsMissingGlobal());
    expect(needs.where((n) => !shipped.contains(n)), ['App.blogs']);
  });
}

void _variantTests() {
  test('variants are unioned, so a flagged capability is not missed', () {
    // A capability behind a feature flag exists on some installs and not
    // others. A manifest built from one variant would reject a patch that is
    // perfectly runnable for the cohort it targets.
    final json =
        jsonDecode(
              capabilityManifest(
                (r, _) => r.registerGlobal('App.base', (_, _) => null),
                variants: [
                  (r, _) => r.registerGlobal('App.betaOnly', (_, _) => null),
                ],
              ),
            )
            as Map<String, Object?>;
    final globals = (json['globals']! as List).cast<String>();

    expect(globals, contains('App.base'));
    expect(globals, contains('App.betaOnly'));
    expect(json['variants'], 2);
  });

  test('with no variants the manifest is unchanged', () {
    final one = jsonDecode(capabilityManifest(null)) as Map<String, Object?>;
    expect(one['variants'], 1);
    expect((one['globals']! as List), contains('Text'));
  });
}

/// A patch can fail permanently in ways no list of exception types anticipates.
/// These cover the failures that used to strand a user on the fallback forever,
/// or worse, be recorded as healthy.
void _strandingTests() {
  testWidgets('a non-Widget return is an error, not a silent ErrorWidget', (
    tester,
  ) async {
    // `build() => 42;` — previously became an ErrorWidget in place. Visible,
    // but invisible to the host: errorBuilder never ran, the patch was marked
    // HEALTHY, and the crash-loop counter reset for a patch that renders
    // nothing usable.
    final f =
        (BytecodeBuilder()
              ..emitLoadInt(0, 42)
              ..emitA(Op.ret, 0))
            .toProto(name: 'build', paramCount: 0, registerCount: 1);
    final module = Module(constants: ConstantPool(), functions: [f]);

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

    expect(find.text('native fallback'), findsOneWidget);
    expect(captured, isA<PatchOutputException>());
    // Permanent: an int-returning build() returns an int every time.
    expect(isUnrunnableOnThisBuild(captured!), isTrue);
    expect(tester.takeException(), isNull);
  });

  test('the classifier names both permanent shapes', () {
    expect(
      isUnrunnableOnThisBuild(
        MissingHostCapabilityException.global('App.blogs'),
      ),
      isTrue,
    );
    expect(isUnrunnableOnThisBuild(PatchOutputException('build', 42)), isTrue);
    // Anything unrecognised stays transient here; repeated failure escalates it
    // in EjenixPatchView, so an unnameable permanent fault still recovers.
    expect(isUnrunnableOnThisBuild(StateError('x')), isFalse);
  });
}
