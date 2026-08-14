// Copyright (c) Ejenix authors. MIT license.

/// Guards the contract between the two halves of the bridge.
///
/// `patch_sdk/flutter.dart` declares what a patch may call; `ejenix_flutter.dart`
/// binds those calls to real Flutter. If someone adds a widget to the SDK and
/// forgets the binding, a patch would compile and then fail at runtime on the
/// user's device — the worst possible place to find out. This test reads the SDK
/// and asserts every declaration it promises is actually registered.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';
import 'package:ejenix_flutter/ejenix_flutter_http.dart';

/// What the patch SDK promises, split by how the compiler lowers it.
class _Surface {
  /// Names lowered to a host global: `Text`, `Image.network`, `Colors.red`.
  final Set<String> globals = {};

  /// `kind` -> selectors lowered to an instance call: `TextEditingController`
  /// -> {`text`, `clear`}.
  final Map<String, Set<String>> methods = {};
}

/// Scans the patch SDK's `external` declarations. A line scanner is deliberate:
/// this package cannot depend on `analyzer` (the Flutter SDK pins an older
/// `meta`), and the SDK file is written in a fixed, simple shape.
_Surface parsePatchSdk(String source) {
  final surface = _Surface();
  String? currentClass;

  for (final raw in source.split('\n')) {
    final line = raw.trim();

    final classDecl = RegExp(r'^(?:abstract )?class (\w+)').firstMatch(line);
    if (classDecl != null) {
      // A one-line body (`class IconData {}`) is a marker type: it opens no
      // scope, and anything after it is top-level again.
      currentClass = line.endsWith('{}') ? null : classDecl.group(1);
      continue;
    }
    if (line == '}') {
      currentClass = null;
      continue;
    }
    if (!line.startsWith('external ')) continue;

    // `external static T get name;` -> global `Class.name`
    final staticGetter = RegExp(
      r'^external static [\w<>?]+ get (\w+);',
    ).firstMatch(line);
    if (staticGetter != null && currentClass != null) {
      surface.globals.add('$currentClass.${staticGetter.group(1)}');
      continue;
    }

    // A top-level `external void setState(...)` -> global `setState`.
    if (currentClass == null) {
      final fn = RegExp(r'^external [\w<>?]+ (\w+)\(').firstMatch(line);
      if (fn != null) surface.globals.add(fn.group(1)!);
      continue;
    }

    // `external Class(...)` / `external Class.named(...)` -> global.
    final ctor = RegExp(
      '^external $currentClass(?:\\.(\\w+))?\\(',
    ).firstMatch(line);
    if (ctor != null) {
      final named = ctor.group(1);
      surface.globals.add(
        named == null ? currentClass : '$currentClass.$named',
      );
      continue;
    }

    // A non-static instance member -> an instance call on that kind.
    final member = RegExp(
      r'^external [\w<>?]+ (?:get )?(\w+)[;(]',
    ).firstMatch(line);
    if (member != null) {
      (surface.methods[currentClass] ??= {}).add(member.group(1)!);
    }
  }
  return surface;
}

void main() {
  final sdkFile = File('patch_sdk/flutter.dart');
  final surface = parsePatchSdk(sdkFile.readAsStringSync());
  final registry = flutterHostRegistry(BridgeContext());

  test('the patch SDK declares a surface worth checking', () {
    // Guards the scanner itself: a regex that silently matched nothing would
    // make every assertion below vacuously pass.
    expect(sdkFile.existsSync(), isTrue);
    expect(surface.globals.length, greaterThan(80));
    expect(surface.methods, contains('TextEditingController'));
  });

  group('the network capability is opt-in', () {
    final httpSurface = parsePatchSdk(
      File('patch_sdk/http.dart').readAsStringSync(),
    );

    test('httpGet is absent from the default registry', () {
      // The security property, asserted rather than assumed: an app that never
      // grants the capability cannot have a patch reach the network.
      expect(httpSurface.globals, contains('httpGet'));
      expect(registry.hasGlobal('httpGet'), isFalse);
    });

    test('registerHttp binds exactly what the opt-in SDK declares', () {
      final granted = flutterHostRegistry(BridgeContext());
      registerHttp(granted, allowedHosts: {'api.example.com'});
      for (final g in httpSurface.globals) {
        expect(granted.hasGlobal(g), isTrue, reason: '$g was not registered');
      }
    });

    test('a denied host is refused before any request', () async {
      final granted = flutterHostRegistry(BridgeContext());
      registerHttp(granted, allowedHosts: {'api.example.com'});
      final get = granted.resolveGlobal('httpGet')!;

      await expectLater(
        get(null, [
              <Object?, Object?>{'url': 'https://evil.test/steal'},
            ])
            as Future<Object?>,
        throwsA(isA<HttpCapabilityDenied>()),
      );
      // Plaintext is refused even for an allowed host.
      await expectLater(
        get(null, [
              <Object?, Object?>{'url': 'http://api.example.com/x'},
            ])
            as Future<Object?>,
        throwsA(isA<HttpCapabilityDenied>()),
      );
    });
  });

  test('every SDK declaration is bound to a host global', () {
    final missing =
        surface.globals.where((g) => !registry.hasGlobal(g)).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'declared in patch_sdk/flutter.dart but never registered in '
          'ejenix_flutter.dart — a patch using these would compile and then '
          'fail on device',
    );
  });

  test('every SDK instance member is bound on its kind', () {
    final missing = <String>[];
    surface.methods.forEach((kind, selectors) {
      for (final s in selectors) {
        if (!registry.hasMethod(kind, s)) missing.add('$kind.$s');
      }
    });
    expect(missing..sort(), isEmpty);
  });

  test('a host object the bridge returns resolves to its kind', () {
    // The kind resolver is what makes `controller.text` reachable at all.
    final controller = registry.resolveGlobal('TextEditingController')!(null, [
      <Object?, Object?>{'text': 'seed'},
    ]);
    expect(registry.resolve(controller, 'text')!(controller, const []), 'seed');
  });
}
