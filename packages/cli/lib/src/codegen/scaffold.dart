// Copyright (c) Ejenix authors. MIT license.

/// Templates for `ejenix scaffold`: a patch stub plus the production host widget
/// that wraps [EjenixPatchView]. Pure string builders so they are trivially
/// testable; the command layer handles the filesystem.
library;

/// `home_screen` → `HomeScreen`.
String pascalCase(String name) => name
    .split('_')
    .where((p) => p.isNotEmpty)
    .map((p) => p[0].toUpperCase() + p.substring(1))
    .join();

/// The interpreted patch a developer edits and ships over the air. Follows the
/// `createState()` + `build(context, state)` entry convention [EjenixPatchView]
/// expects by default.
String scaffoldPatch({required String name, required String sdkPrefix}) {
  final cls = pascalCase(name);
  return '''// The $name screen, as an interpreted patch.
//
// Compiled to bytecode, signed, and shipped over the air — it is NOT in the app
// binary. Change it, re-publish, and the screen updates on devices in the field
// in minutes instead of a release cycle. A patch reaches the outside world only
// through the two imports below: the widgets the bridge exposes, and the
// capabilities this app granted (generate them with `ejenix gen`). Anything else
// fails to compile — and a patch must stay within the app you submitted.

import '$sdkPrefix/flutter.dart';
import '$sdkPrefix/app.dart';

/// Patch-local state, created once and preserved across rebuilds.
class ${cls}State {}

${cls}State createState() => ${cls}State();

Widget build(BuildContext context, ${cls}State state) {
  return Scaffold(
    appBar: AppBar(title: Text('$cls')),
    body: Center(
      child: Text('Edit patches/$name.dart, then run `ejenix build` and push.'),
    ),
  );
}
''';
}

/// The production host widget: renders the cached patch instantly, checks the
/// control plane on launch and resume, verifies and swaps newer patches, and
/// rolls back on a crash loop. The developer fills the three `TODO`s (control
/// plane, app id, trusted key) and the generated capabilities.
String scaffoldView({required String name, required String appId}) {
  final cls = pascalCase(name);
  return '''// Copyright (c) Ejenix authors. MIT license.

import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';

// After `ejenix gen`, import your capabilities and pass them to `extend:` below.
// import 'app_capabilities.g.dart';

/// Hosts the interpreted `$name` screen. Offline-first and fail-soft: it shows
/// the cached patch immediately, updates over the air when the control plane has
/// a newer verified patch, and falls back to [_fallback] if none is available.
class ${cls}View extends StatelessWidget {
  const ${cls}View({super.key});

  // TODO: the Ed25519 public key(s) this build trusts — your release.key.pub
  // bytes. A patch signed by any other key is discarded, never run.
  static final List<Uint8List> _trustedKeys = <Uint8List>[];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Boot>(
      future: _boot(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final boot = snapshot.data!;
        return EjenixPatchView(
          controlPlane: Uri.parse('https://your-control-plane.example'), // TODO
          appId: '$appId', // TODO
          // Which environment this build follows. Stated explicitly on purpose:
          // it defaults to 'production', so a view that omits it polls
          // production while you promote to staging — and the patch silently
          // never arrives.
          env: 'staging', // TODO: 'production' for a store build
          trustedKeys: _trustedKeys,
          cacheDir: boot.cacheDir,
          bundledFallback: boot.fallback,
          // extend: appCapabilities(...), // TODO: from `ejenix gen`
          fallbackBuilder: (context, error) => _fallback(context, error),
        );
      },
    );
  }

  Widget _fallback(BuildContext context, Object? error) => Scaffold(
    appBar: AppBar(title: const Text('$cls')),
    body: const Center(child: Text('Running the built-in screen.')),
  );

  Future<_Boot> _boot() async {
    final cacheDir = await getApplicationSupportDirectory();
    // The patch you ship inside the binary, so the screen works on first launch
    // and offline. Build it: `ejenix build patches/$name.dart -o $name.bundle`.
    Uint8List? fallback;
    try {
      final data = await rootBundle.load('assets/$name.bundle');
      fallback = data.buffer.asUint8List();
    } catch (_) {
      fallback = null; // No bundled fallback shipped yet — that is fine.
    }
    return _Boot(cacheDir, fallback);
  }
}

class _Boot {
  _Boot(this.cacheDir, this.fallback);
  final Directory cacheDir;
  final Uint8List? fallback;
}
''';
}
