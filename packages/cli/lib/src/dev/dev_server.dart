// Copyright (c) Ejenix authors. MIT license.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Serves the freshest signed patch to a running app, and tells it the moment a
/// new one is ready.
///
/// Three endpoints, deliberately boring:
///
/// * `GET /patch.bundle` — the current signed bundle bytes.
/// * `GET /events` — Server-Sent Events; one line per build, carrying the new
///   bundle id. The app re-fetches `/patch.bundle` when it sees one.
/// * `GET /health` — `{"ok":true}`, so `ejenix watch` is scriptable.
///
/// SSE rather than a WebSocket: the traffic is one-directional (server tells the
/// app to reload), it is plain HTTP so it needs no dependency and no handshake,
/// and it reconnects on its own. A WebSocket would buy nothing here.
///
/// **This is a development server.** It binds loopback by default and serves an
/// unauthenticated bundle to whoever asks. It is not, and must not become, the
/// delivery path — that is the signed control-plane flow in `packages/server`.
/// The app still verifies the signature on what it receives here, so a patch
/// served by this server is no more trusted than one off the network.
class PatchDevServer {
  PatchDevServer({this.onLog});

  /// Reports what connected apps are doing — subscribe, fetch, disconnect.
  ///
  /// Without this, "the phone isn't updating" is pure guesswork: you cannot tell
  /// a device that never connected from one whose stream silently died. A dev
  /// server that keeps that to itself is not much of a dev server.
  final void Function(String message)? onLog;

  HttpServer? _server;
  final List<HttpResponse> _clients = [];
  Timer? _heartbeat;

  /// How often an idle SSE stream emits a comment line.
  ///
  /// An SSE connection that sends nothing between builds is indistinguishable
  /// from a dead one, and anything between the server and the app — a proxy, a
  /// platform socket layer — is free to sit on the bytes or drop the stream. A
  /// periodic comment keeps the stream provably alive and keeps writes moving.
  static const _heartbeatInterval = Duration(seconds: 1);

  Uint8List? _bundle;
  String? _bundleId;

  /// The port actually bound (useful when starting on port 0 in tests).
  int get port => _server?.port ?? 0;

  /// How many apps are currently subscribed. Lets the CLI say "1 device
  /// connected" instead of leaving you wondering.
  int get clientCount => _clients.length;

  /// The bundle id currently being served, or `null` before the first build.
  String? get bundleId => _bundleId;

  /// Binds and starts serving. Defaults to loopback: a dev server that listens
  /// on every interface by default is how a laptop ends up serving bytecode to
  /// the coffee shop.
  Future<void> start({Object? address, int port = 8787}) async {
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    unawaited(_serve(server));
    // Keep idle streams moving. Cancelled in [close].
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _ping());
  }

  /// Writes a comment line to every subscriber. SSE clients ignore `:` lines,
  /// so this is invisible to the app but keeps the connection — and the write
  /// path behind it — demonstrably alive between builds.
  void _ping() {
    for (final client in [..._clients]) {
      try {
        client.write(': ping\n\n');
        unawaited(client.flush());
      } on Object {
        _clients.remove(client);
      }
    }
  }

  /// Accepts connections and dispatches each one *without* awaiting it.
  ///
  /// The accept loop must never block on a single request. `/events` is a
  /// long-lived SSE stream whose final `flush()` is not guaranteed to complete
  /// promptly — on Windows it does not — and awaiting it here stopped the
  /// server from accepting anything else for as long as one device stayed
  /// subscribed. A connected app would then hang the very `/patch.bundle`
  /// fetch it made in response to an event.
  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case '/patch.bundle':
          _servePatch(request);
        case '/events':
          await _subscribe(request);
        case '/health':
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true, 'bundleId': _bundleId}));
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    } on Object {
      // A client that vanished mid-response must not take the server with it.
    }
  }

  String _peer(HttpRequest r) =>
      r.connectionInfo?.remoteAddress.address ?? 'unknown';

  void _servePatch(HttpRequest request) {
    onLog?.call('${_peer(request)} fetched the patch');
    final bundle = _bundle;
    if (bundle == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      unawaited(request.response.close());
      return;
    }
    request.response
      ..headers.contentType = ContentType.binary
      ..headers.set('cache-control', 'no-store')
      ..headers.set('x-bundle-id', _bundleId ?? '')
      ..add(bundle);
    unawaited(request.response.close());
  }

  Future<void> _subscribe(HttpRequest request) async {
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.set('content-type', 'text/event-stream')
      ..headers.set('cache-control', 'no-store')
      ..headers.set('connection', 'keep-alive')
      // Chunked framing would buffer; SSE must flush per event.
      ..bufferOutput = false;

    _clients.add(response);
    onLog?.call('${_peer(request)} subscribed (${_clients.length} connected)');

    // Write a comment (SSE clients ignore `:` lines) before anything else. A
    // response with no body written yet has not sent its headers, so an app that
    // connects *before* the first build would block waiting for them. This
    // forces the headers out immediately.
    response.write(': connected\n\n');

    // Tell a late joiner what is already live, so it does not sit blank waiting
    // for the next edit.
    if (_bundleId != null) response.write('data: $_bundleId\n\n');

    // Deliberately no `flush()` here. `bufferOutput = false` already sends each
    // write as soon as it can, so the flush bought nothing — and on Windows its
    // future never completes on a keep-alive event-stream response. Everything
    // written to the sink afterwards then queues behind it forever: the app
    // received `: connected` and never saw another event, and the accept loop
    // that used to await this call stopped serving entirely.

    // Drop the client when it disconnects.
    unawaited(
      response.done.catchError((Object _) {}).whenComplete(() {
        _clients.remove(response);
        onLog?.call(
          '${_peer(request)} disconnected (${_clients.length} connected)',
        );
      }),
    );
  }

  /// Makes [bundle] the live patch and notifies every subscriber.
  void publish(Uint8List bundle, String bundleId) {
    _bundle = bundle;
    _bundleId = bundleId;
    for (final client in [..._clients]) {
      try {
        client.write('data: $bundleId\n\n');
        unawaited(client.flush());
      } on Object {
        // A client that vanished mid-write is simply gone; `done` removes it.
        _clients.remove(client);
      }
    }
  }

  Future<void> close() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    for (final client in [..._clients]) {
      try {
        await client.close();
      } on Object {
        // Already gone.
      }
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
