// Copyright (c) Ejenix authors. MIT license.

/// Where a patch comes from — and why the answer matters.
///
/// The app can take its patch from two places, and **both go through the same
/// verification**. That is the point: the byte source is untrusted either way, so
/// trust comes from the signature, never from where the bytes arrived.
///
/// * **The bundled asset** — what ships in the binary. Always present, so the app
///   works offline and on first launch.
/// * **The network** — a live `ejenix watch` dev server, or (in production) the
///   control plane via `package:ejenix_loader`. This is the *push* half:
///   new bytes arrive and the screen changes, with no rebuild of the app binary.
///
/// A patch that fails verification is discarded and the previous one keeps
/// running. A compromised server cannot make the app execute anything, because it
/// cannot forge a signature from the key compiled into the binary.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:ejenix_flutter/ejenix_flutter.dart';

import 'main.dart' show verifyPatch;

/// Where the patch currently on screen came from.
enum PatchOrigin {
  /// Shipped inside the binary.
  bundled,

  /// Pushed over the network and verified. This is over-the-air patching working.
  pushed,
}

/// A verified patch plus where it came from.
class VerifiedPatch {
  const VerifiedPatch(this.module, this.origin);
  final Module module;
  final PatchOrigin origin;
}

/// Streams verified patches: the bundled one first, then any the dev server
/// pushes.
class PatchChannel {
  PatchChannel({
    required this.assetPath,
    required this.trustedPublicKeyHex,
    this.devServerUrl,
  });

  /// A human-readable connection state, so a failure is **visible** rather than
  /// silent. A dev loop that cannot tell you why the phone is not updating is
  /// worse than no dev loop — you would sit there editing a file and wondering.
  final ValueNotifier<String> status = ValueNotifier('starting…');

  /// The patch that shipped in the binary.
  final String assetPath;

  /// The key this build trusts. The root of trust; nothing else grants it.
  final String trustedPublicKeyHex;

  /// A live `ejenix watch` server, e.g. `http://192.168.1.10:8787`. When null,
  /// only the bundled asset is used.
  final String? devServerUrl;

  final _controller = StreamController<VerifiedPatch>.broadcast();

  /// Two clients on purpose. The SSE response is a long-lived stream that is
  /// never drained; sharing a connection pool with the bundle fetches let a fetch
  /// disturb the stream — which is exactly how the first push landed and every
  /// one after it silently vanished.
  HttpClient? _eventClient;
  HttpClient? _fetchClient;

  StreamSubscription<String>? _events;
  String? _liveBundleId;
  bool _stopped = false;
  int _attempt = 0;

  /// Verified patches, newest last. The first event is the bundled asset.
  Stream<VerifiedPatch> get patches => _controller.stream;

  Future<void> start() async {
    await _loadAsset();
    final url = devServerUrl;
    if (url == null || url.isEmpty) {
      status.value = 'bundled patch (no dev server configured)';
      return;
    }
    status.value = 'connecting to $url…';
    unawaited(_followDevServer(url));
  }

  Future<void> _loadAsset() async {
    try {
      final data = await rootBundle.load(assetPath);
      _controller.add(
        VerifiedPatch(
          verifyPatch(
            data.buffer.asUint8List(),
            trustedPublicKeyHex: trustedPublicKeyHex,
          ),
          PatchOrigin.bundled,
        ),
      );
    } on Object catch (e) {
      _controller.addError(e);
    }
  }

  /// Subscribes to the dev server's SSE stream and re-fetches on each build,
  /// **reconnecting** if the stream drops.
  ///
  /// Reconnection is not a nicety. A phone sleeps, Wi-Fi hiccups, the dev server
  /// restarts — and without this the app goes permanently deaf to pushes while
  /// still *looking* connected. Errors are surfaced into [status] rather than
  /// swallowed, for the same reason.
  Future<void> _followDevServer(String base) async {
    if (_stopped) return;

    final client = _eventClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(hours: 1);

    try {
      final response = await (await client.getUrl(
        Uri.parse('$base/events'),
      )).close();

      _attempt = 0;
      status.value = 'live — connected to the dev server';

      _events = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data: '))
          .listen(
            (line) {
              final bundleId = line.substring(6).trim();
              if (bundleId.isEmpty || bundleId == _liveBundleId) return;
              _liveBundleId = bundleId;
              // Deliberately not awaited inside the stream callback: a fetch must
              // not stall the event stream that produced it.
              unawaited(_fetch(base));
            },
            // The stream ending is normal (server restarted, Wi-Fi blipped) —
            // reconnect rather than dying quietly.
            onDone: () => _reconnect(base, 'stream closed'),
            onError: (Object e) => _reconnect(base, '$e'),
            cancelOnError: true,
          );
    } on Object catch (e) {
      _reconnect(base, '$e');
    }
  }

  void _reconnect(String base, String why) {
    if (_stopped) return;
    _attempt++;
    final wait = Duration(seconds: (_attempt * 2).clamp(1, 10));
    status.value =
        'dev server unreachable — running the last good patch\n'
        'retrying in ${wait.inSeconds}s ($why)';
    Future<void>.delayed(wait, () => _followDevServer(base));
  }

  Future<void> _fetch(String base) async {
    final client = _fetchClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final response = await (await client.getUrl(
        Uri.parse('$base/patch.bundle'),
      )).close();
      if (response.statusCode != HttpStatus.ok) return;

      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }

      // The pushed bytes are verified exactly like the bundled ones. A dev
      // server is not a trusted source; the signature is.
      _controller.add(
        VerifiedPatch(
          verifyPatch(
            Uint8List.fromList(chunks),
            trustedPublicKeyHex: trustedPublicKeyHex,
          ),
          PatchOrigin.pushed,
        ),
      );
      status.value = 'live — pushed patch applied';
    } on Object catch (e) {
      // A patch that does not verify is dropped; the running one keeps going.
      // This is the security boundary doing its job, so make it loud.
      status.value = 'REJECTED a pushed patch — $e';
    }
  }

  Future<void> dispose() async {
    _stopped = true;
    await _events?.cancel();
    _eventClient?.close(force: true);
    _fetchClient?.close(force: true);
    status.dispose();
    await _controller.close();
  }
}
