// Copyright (c) Ejenix authors. MIT license.

/// Proves the whole chain the example is meant to demonstrate:
///
/// real patch source → compiled + **signed** by the toolchain → verified against
/// the trusted key → interpreted → renders **the app's own widgets** and drives
/// **the app's own state**.
///
/// Run `example/patchable_app/build.sh` first; it produces the bundle and key
/// these tests read.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';
import 'package:patchable_app/app_capabilities.g.dart';
import 'package:patchable_app/app_state.dart';
import 'package:patchable_app/design_system.dart';
import 'package:patchable_app/main.dart';

final _bundle = File('assets/home_screen.bundle');
final _pubKey = File('keys/dev.key.pub');

void main() {
  setUpAll(() {
    if (!_bundle.existsSync() || !_pubKey.existsSync()) {
      fail('run example/patchable_app/build.sh first (missing patch/key)');
    }
  });

  Module patch() => verifyPatch(
    _bundle.readAsBytesSync(),
    trustedPublicKeyHex: _pubKey.readAsStringSync(),
  );

  /// Pumps the interpreted patch with the app's capabilities granted.
  Future<TodoRepository> pumpPatch(WidgetTester tester) async {
    final repo = TodoRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: InterpretedView(module: patch(), extend: appCapabilities(repo)),
      ),
    );
    return repo;
  }

  group('signature verification gates execution', () {
    test('a patch signed by the trusted key is accepted', () {
      expect(patch().functions, isNotEmpty);
    });

    test('a patch signed by another key is rejected, not run', () {
      // Same bytes, a key the binary does not trust. This is the whole defence
      // against a compromised update server.
      const attackerKey =
          '0000000000000000000000000000000000000000000000000000000000000000';
      expect(
        () => verifyPatch(
          _bundle.readAsBytesSync(),
          trustedPublicKeyHex: attackerKey,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a tampered patch is rejected', () {
      final bytes = _bundle.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0xFF; // flip a bit in the signed body
      expect(
        () =>
            verifyPatch(bytes, trustedPublicKeyHex: _pubKey.readAsStringSync()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the patch renders through the app the app granted', () {
    testWidgets('it renders the app’s own design-system widgets', (
      tester,
    ) async {
      await pumpPatch(tester);

      // Not generic Material: these are the app's widgets, reached only because
      // `appCapabilities` registered them.
      expect(find.byType(StatCard), findsOneWidget);
      expect(find.byType(PrimaryButton), findsOneWidget);
      expect(find.text('Todos'), findsOneWidget);
    });

    testWidgets('it reads the app’s state', (tester) async {
      final repo = await pumpPatch(tester);

      // Two of the three seeded todos are pending.
      expect(repo.pendingCount, 2);
      expect(find.text('2'), findsOneWidget); // the StatCard value
      expect(find.text('Write the patch SDK'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(3));
    });

    testWidgets('it mutates the app’s state through a granted capability', (
      tester,
    ) async {
      final repo = await pumpPatch(tester);

      await tester.enterText(find.byType(TextField), 'Ship it');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();

      // The patch called App.addTodo, which mutated the *app's* repository...
      expect(repo.todosForPatch.last['title'], 'Ship it');
      // ...and the rebuild shows it.
      expect(find.text('Ship it'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(4));
    });

    testWidgets('a checkbox toggles the app’s state', (tester) async {
      final repo = await pumpPatch(tester);
      expect(repo.pendingCount, 2);

      // Toggle the second todo (the first seeded one is already done).
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();

      expect(repo.pendingCount, 1);
      expect(find.text('1'), findsOneWidget); // StatCard updated
    });

    testWidgets('a granted async service runs and rebuilds', (tester) async {
      final repo = await pumpPatch(tester);
      final before = repo.todosForPatch.length;

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      // App.refresh() awaited the app's (simulated) network call, then asked the
      // view to rebuild — the patch never touched the network itself.
      expect(repo.todosForPatch.length, before + 1);
    });

    testWidgets('navigation and snackbars reach the app’s shell', (
      tester,
    ) async {
      await pumpPatch(tester);

      await tester.tap(find.text('Ship the interpreter'));
      await tester.pump(); // let the SnackBar animate in

      expect(find.text('Tapped Ship the interpreter'), findsOneWidget);
    });
  });

  group('the app’s capability surface and its SDK agree', () {
    test('every name in patch_sdk/app.dart is registered', () {
      // The same drift guard the bridge applies to its own SDK: a capability
      // declared but never bound would compile and then fail on a user's phone.
      final sdk = File('patch_sdk/app.dart').readAsStringSync();
      final declared = RegExp(
        r'external (?:static )?[\w<>?, ]+ (?:get )?(\w+)',
      ).allMatches(sdk).map((m) => m.group(1)!).toSet();

      final ctx = BridgeContext();
      final registry = flutterHostRegistry(ctx);
      appCapabilities(TodoRepository())(registry, ctx);

      for (final name in declared) {
        final bound =
            registry.hasGlobal(name) || // PrimaryButton, StatCard
            registry.hasGlobal('App.$name'); // App.todos, App.addTodo, …
        expect(bound, isTrue, reason: '`$name` is declared but not registered');
      }
      expect(declared, contains('addTodo')); // the scanner really matched
    });
  });
}
