// Copyright (c) Ejenix authors. MIT license.

/// End-to-end tests for the bridge: **real Dart patch source** → compiled
/// bytecode → interpreted → **real Flutter widgets**.
///
/// The fixtures under `test/fixtures/` are compiled from the patch sources in
/// `tool/gen_bridge_fixtures.dart` (run from the repo root), because this
/// package cannot depend on `ejenix_compiler` — the Flutter SDK pins an older
/// `meta` than `analyzer` requires. Hand-assembling bytecode here would prove
/// the *interpreter* works but not that a patch a developer actually writes
/// compiles and renders; these tests close that gap.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';

/// Decodes the compiled patch named [name] from `test/fixtures/`.
Module fixture(String name) {
  final file = File('test/fixtures/$name.mod');
  if (!file.existsSync()) {
    fail(
      'missing fixture ${file.path} — run `dart run tool/gen_bridge_fixtures.dart` '
      'from the repo root',
    );
  }
  final (module, _) = ModuleCodec.decodeBody(file.readAsBytesSync());
  return module;
}

/// Pumps an interpreted patch inside a real app shell.
Future<void> pumpPatch(WidgetTester tester, String name) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: InterpretedView(module: fixture(name))),
  ),
);

void main() {
  group('app capability drift', _appCapabilityDriftTests);

  group('the widgets a real mobile screen needs', () {
    testWidgets('overlays, insets, wrapping chips, clipping, transforms', (
      tester,
    ) async {
      // Via `pumpPatch`, so the patch sits under a Scaffold — Chip and friends
      // are Material widgets and need a Material ancestor, exactly as they do in
      // a real app.
      await pumpPatch(tester, 'mobile_chrome');

      // Registered is not the same as working: assert each one is really in the
      // tree, built by interpreted bytecode.
      expect(find.byType(SafeArea), findsOneWidget);
      expect(find.byType(Stack), findsWidgets);
      expect(find.byType(Wrap), findsOneWidget);
      expect(find.byType(ClipRRect), findsOneWidget);
      expect(find.byType(Transform), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.text('overlay'), findsOneWidget);
    });

    testWidgets('tabs render and switch', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: InterpretedView(module: fixture('tabs'))),
      );

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('One'), findsOneWidget);
      expect(find.text('first'), findsOneWidget);

      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('a radio group and a dropdown drive patch state', (
      tester,
    ) async {
      await pumpPatch(tester, 'forms');

      expect(find.text('choice=a'), findsOneWidget);

      // Selection lives on the RadioGroup ancestor (Flutter's current API), so
      // tapping the second radio must round-trip through the VM and back.
      await tester.tap(find.byType(Radio<Object?>).last);
      await tester.pumpAndSettle();
      expect(find.text('choice=b'), findsOneWidget);

      expect(find.byType(DropdownButton<Object?>), findsOneWidget);
    });
  });

  mainOriginal();
}

void mainOriginal() {
  testWidgets('a stateless patch renders a real widget tree', (tester) async {
    await pumpPatch(tester, 'hello');

    expect(find.text('Hello from a patch'), findsOneWidget);
    expect(find.text('rendered by the interpreter'), findsOneWidget);
    expect(find.byType(Column), findsOneWidget);
    // The TextStyle the patch asked for reached the real widget.
    expect(
      tester.widget<Text>(find.text('Hello from a patch')).style?.fontSize,
      24.0,
    );
  });

  testWidgets('a tap re-enters the VM and setState rebuilds', (tester) async {
    await pumpPatch(tester, 'counter');

    expect(find.text('Count: 0'), findsOneWidget);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(find.text('Count: 1'), findsOneWidget);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    // State survived the rebuild: the interpreted state object is held once.
    expect(find.text('Count: 2'), findsOneWidget);
  });

  testWidgets('a one-argument onChanged callback carries its value', (
    tester,
  ) async {
    await pumpPatch(tester, 'text_input');

    expect(find.text('Hello, '), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Ada');
    await tester.pump();
    // The typed value crossed the boundary into the VM and back out.
    expect(find.text('Hello, Ada'), findsOneWidget);
  });

  testWidgets('an itemBuilder returns a widget per row', (tester) async {
    await pumpPatch(tester, 'list_builder');

    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Row 1'), findsOneWidget);
    expect(find.text('Row 2'), findsOneWidget);
  });

  testWidgets('a bool onChanged round-trips through the VM', (tester) async {
    await pumpPatch(tester, 'toggles');

    expect(find.text('OFF'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('ON'), findsOneWidget);
  });
}

/// The production failure, reproduced with a **real compiled patch** rather than
/// hand-assembled bytecode: `app_capability.mod` is Dart source compiled by the
/// real toolchain that calls `appBlogsTitle()`, an app capability.
///
/// Whether it runs depends entirely on whether the host registers that
/// capability — which is exactly the drift that produced
/// `no host global 'App.blogs'` on a user's phone. Both directions are asserted,
/// because a fix that stops the crash but also stops working patches is worse
/// than the bug.
void _appCapabilityDriftTests() {
  testWidgets('a patch needing an unregistered capability shows the fallback', (
    tester,
  ) async {
    Object? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: InterpretedView(
          module: fixture('app_capability'),
          // extend deliberately omitted: the binary predates the capability.
          errorBuilder: (_, e) {
            captured = e;
            return const Text('native fallback');
          },
        ),
      ),
    );

    expect(find.text('native fallback'), findsOneWidget);
    expect(captured, isA<MissingHostCapabilityException>());
    expect(
      (captured! as MissingHostCapabilityException).selector,
      'appBlogsTitle',
    );
    expect(isUnrunnableOnThisBuild(captured!), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same patch renders once the app registers it', (
    tester,
  ) async {
    // The false-positive control. If this ever fails, the fix has started
    // rejecting patches that work.
    await tester.pumpWidget(
      MaterialApp(
        home: InterpretedView(
          module: fixture('app_capability'),
          extend: (r, _) =>
              r.registerGlobal('appBlogsTitle', (_, _) => 'Latest posts'),
          errorBuilder: (_, e) => Text('should not happen: $e'),
        ),
      ),
    );

    expect(find.text('Blogs'), findsOneWidget);
    expect(find.text('Latest posts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
