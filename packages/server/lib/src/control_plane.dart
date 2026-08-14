// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_delta/delta.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'brand.dart';
import 'dashboard.dart';
import 'model.dart';
import 'observability.dart';
import 'store.dart';

class _HttpError implements Exception {
  _HttpError(this.status, this.message);
  final int status;
  final String message;
}

/// The control-plane REST API (brief §6.8).
///
/// A `shelf_router` [Router] behind a pipeline that assigns a request id, logs
/// structured JSON, and records Prometheus metrics. App creation and app-scoped
/// mutations require bearer keys; bundle downloads are public because bundles
/// are signed (the transport carries no secret). The server holds a delivery
/// [Signer] used only to sign on-demand deltas.
class ControlPlane {
  ControlPlane({
    required this.store,
    required String adminApiKey,
    required this.deliverySigner,
    Metrics? metrics,
    void Function(Map<String, Object?> entry)? logSink,
    Random? random,
  }) : _adminKeyHash = hashApiKey(adminApiKey),
       metrics = metrics ?? Metrics(),
       _random = random ?? Random.secure(),
       _logSink = logSink;

  final Store store;
  final Signer deliverySigner;
  final Metrics metrics;
  final String _adminKeyHash;
  final Random _random;
  final void Function(Map<String, Object?> entry)? _logSink;

  /// The composed request handler.
  Handler get handler {
    final router = Router()
      ..post('/v1/apps', _createApp)
      ..get('/v1/apps', _listApps)
      ..post('/v1/apps/<app>/bundles', _uploadBundle)
      ..get('/v1/apps/<app>/bundles', _listBundles)
      ..get('/v1/apps/<app>/bundles/<file>', _downloadBundle)
      ..get('/v1/apps/<app>/envs', _listEnvs)
      ..post('/v1/apps/<app>/envs/<env>/active', _setActive)
      ..post('/v1/apps/<app>/envs/<env>/rollback', _rollbackEnv)
      ..get('/v1/apps/<app>/envs/<env>/active', _getActive)
      ..post('/v1/apps/<app>/deltas', _computeDelta)
      ..get('/', _dashboard)
      ..get('/dashboard', _dashboard)
      ..get('/brand/logo.png', _brandLogo)
      ..get('/brand/inter.woff2', _brandInter)
      ..get('/brand/jetbrains-mono.woff2', _brandMono)
      ..get('/v1/health', (Request r) => _json(200, {'status': 'ok'}))
      ..get('/v1/ready', _ready)
      ..get('/metrics', _metricsHandler);

    return Pipeline()
        .addMiddleware(
          observability(metrics: metrics, logSink: _logSink, random: _random),
        )
        .addMiddleware(_errorMiddleware())
        .addHandler(router.call);
  }

  Middleware _errorMiddleware() => (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on _HttpError catch (e) {
        return _json(e.status, {'error': e.message});
      } on FormatException catch (e) {
        return _json(400, {'error': 'bad request: ${e.message}'});
      } on Object catch (e) {
        _logSink?.call({'level': 'error', 'error': '$e'});
        return _json(500, {'error': 'internal server error'});
      }
    };
  };

  // --- Apps ---

  Future<Response> _createApp(Request request) async {
    _requireAdmin(request);
    final body = await _readJson(request);
    final id = body['id'] as String?;
    if (id == null || !_validSlug(id)) {
      throw _HttpError(400, 'invalid or missing app id (slug required)');
    }
    if (await store.getApp(id) != null) {
      throw _HttpError(409, 'app already exists: $id');
    }
    final keys = [
      for (final k in (body['trustedKeys'] as List? ?? const []))
        _unhex(k as String),
    ];
    if (keys.isEmpty || keys.any((k) => k.length != 32)) {
      throw _HttpError(
        400,
        'at least one 32-byte trustedKey (hex) is required',
      );
    }
    final apiKey = generateApiKey(_random);
    final app = App(
      id: id,
      name: (body['name'] as String?) ?? id,
      apiKeyHash: hashApiKey(apiKey),
      trustedKeys: keys,
      createdAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await store.putApp(app);
    return _json(201, {...app.toPublicJson(), 'apiKey': apiKey});
  }

  Future<Response> _listApps(Request request) async {
    _requireAdmin(request);
    final apps = await store.listApps();
    return _json(200, {
      'apps': [for (final a in apps) a.toPublicJson()],
    });
  }

  // --- Bundles ---

  Future<Response> _uploadBundle(Request request, String appId) async {
    final app = await _authorizeApp(request, appId);
    final bytes = await _readBytes(request);
    final Bundle bundle;
    try {
      bundle = Bundle.decode(bytes);
    } on BundleFormatException catch (e) {
      throw _HttpError(400, 'malformed bundle: ${e.message}');
    }
    final verification = bundle.verify(anchors: TrustAnchors(app.trustedKeys));
    if (!verification.isValid) {
      throw _HttpError(
        400,
        'bundle failed verification: ${verification.failure!.name}',
      );
    }
    // A bundle id names a release, so it must never name two different sets of
    // bytes. Overwriting silently split the fleet: devices holding the old
    // bytes revalidated with If-None-Match, got 304, and kept them, while fresh
    // devices got the new bytes under the same id — with the control plane
    // reporting a single active release the whole time.
    final existing = await store.getBundle(appId, bundle.bundleId);
    if (existing != null && !_sameBytes(existing, bytes)) {
      throw _HttpError(
        409,
        'bundle ${formatUuid(bundle.bundleId)} already exists with different '
        'content; publish under a new bundle id',
      );
    }
    await store.putBundle(appId, bundle.bundleId, bytes);
    await store.putBundleRef(
      appId,
      BundleRef(
        bundleId: bundle.bundleId,
        sizeBytes: bytes.length,
        uploadedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    metrics.recordUpload(bytes.length);
    return _json(201, {
      'bundleId': formatUuid(bundle.bundleId),
      'sizeBytes': bytes.length,
    });
  }

  Future<Response> _downloadBundle(
    Request request,
    String appId,
    String file,
  ) async {
    await _getAppOr404(appId);
    if (!file.endsWith('.bundle')) throw _HttpError(404, 'not found');
    final id = _parseBundleId(file.substring(0, file.length - 7));
    final bytes = await store.getBundle(appId, id);
    if (bytes == null) throw _HttpError(404, 'bundle not found');

    // Derived from the bytes, not the id: an ETag is a promise that identical
    // validators mean identical content, and an id-based one cannot keep it.
    final etag = '"${_hex(sha256.convert(bytes).bytes)}"';
    if (request.headers['if-none-match'] == etag) {
      return Response(304, headers: {'etag': etag});
    }
    return Response.ok(
      bytes,
      headers: {'content-type': 'application/octet-stream', 'etag': etag},
    );
  }

  Future<Response> _listBundles(Request request, String appId) async {
    await _authorizeApp(request, appId);
    final refs = await store.listBundleRefs(appId);
    return _json(200, {
      'bundles': [for (final r in refs) r.toJson()],
    });
  }

  // --- Environments ---

  Future<Response> _listEnvs(Request request, String appId) async {
    await _getAppOr404(appId);
    final envs = await store.listEnvs(appId);
    return _json(200, {
      'environments': [for (final e in envs) e.toJson()],
    });
  }

  Future<Response> _setActive(Request request, String appId, String env) async {
    _requireSlug(env, 'environment name');
    await _authorizeApp(request, appId);
    final body = await _readJson(request);
    final id = _parseBundleId(
      (body['bundleId'] as String?) ??
          (throw _HttpError(400, 'missing bundleId')),
    );
    if (await store.getBundle(appId, id) == null) {
      throw _HttpError(404, 'bundle not found for this app');
    }
    final current = await store.getEnv(appId, env);
    await store.putEnv(
      Env(
        appId: appId,
        name: env,
        activeBundleId: id,
        previousBundleId: current?.activeBundleId,
      ),
    );
    metrics.recordActivation(env);
    return _json(200, {'env': env, 'activeBundleId': formatUuid(id)});
  }

  Future<Response> _rollbackEnv(
    Request request,
    String appId,
    String env,
  ) async {
    _requireSlug(env, 'environment name');
    await _authorizeApp(request, appId);
    final current = await store.getEnv(appId, env);
    final previous = current?.previousBundleId;
    if (previous == null) {
      throw _HttpError(409, 'no previous bundle to roll back to for $env');
    }
    await store.putEnv(
      Env(
        appId: appId,
        name: env,
        activeBundleId: previous,
        previousBundleId: current!.activeBundleId,
      ),
    );
    metrics.recordActivation(env);
    return _json(200, {
      'env': env,
      'activeBundleId': formatUuid(previous),
      'rolledBackFrom': formatUuid(current.activeBundleId!),
    });
  }

  Future<Response> _getActive(Request request, String appId, String env) async {
    // Unauthenticated (devices poll it), so this guard is the only thing
    // between a crafted URL and an arbitrary path read.
    _requireSlug(env, 'environment name');
    await _getAppOr404(appId);
    final environment = await store.getEnv(appId, env);
    final active = environment?.activeBundleId;
    if (active == null) throw _HttpError(404, 'no active bundle for $env');
    return _json(200, {'env': env, 'activeBundleId': formatUuid(active)});
  }

  // --- Deltas ---

  Future<Response> _computeDelta(Request request, String appId) async {
    await _authorizeApp(request, appId);
    final body = await _readJson(request);
    final baseId = _parseBundleId(body['base'] as String);
    final targetId = _parseBundleId(body['target'] as String);
    final baseBytes = await store.getBundle(appId, baseId);
    final targetBytes = await store.getBundle(appId, targetId);
    if (baseBytes == null) throw _HttpError(404, 'base bundle not found');
    if (targetBytes == null) throw _HttpError(404, 'target bundle not found');

    final delta = DeltaBundle.create(
      base: Bundle.decode(baseBytes),
      target: Bundle.decode(targetBytes),
      signer: deliverySigner,
      compilerVersion: 'server',
    );
    return Response.ok(
      delta.encode(),
      headers: {'content-type': 'application/octet-stream'},
    );
  }

  // --- Ops ---

  Future<Response> _ready(Request request) async {
    final ok = await store.isHealthy();
    return _json(ok ? 200 : 503, {'ready': ok});
  }

  Response _metricsHandler(Request request) => Response.ok(
    metrics.render(),
    headers: {'content-type': 'text/plain; version=0.0.4'},
  );

  // --- Auth ---

  void _requireAdmin(Request request) {
    final token = bearerToken(request);
    if (token == null ||
        !constantTimeEquals(hashApiKey(token), _adminKeyHash)) {
      throw _HttpError(401, 'admin authorization required');
    }
  }

  Future<App> _authorizeApp(Request request, String appId) async {
    final app = await _getAppOr404(appId);
    final token = bearerToken(request);
    // The app's own key authorizes it; the admin key authorizes every app, so
    // an operator (and the dashboard) can manage the whole control plane.
    if (token != null &&
        (constantTimeEquals(hashApiKey(token), app.apiKeyHash) ||
            constantTimeEquals(hashApiKey(token), _adminKeyHash))) {
      return app;
    }
    throw _HttpError(401, 'app authorization required');
  }

  Future<App> _getAppOr404(String appId) async {
    // Before any store lookup: `appId` comes straight off the URL and the file
    // store interpolates it into a path. Every route reaches the store through
    // here, so this is the one place that has to hold.
    _requireSlug(appId, 'app id');
    final app = await store.getApp(appId);
    if (app == null) throw _HttpError(404, 'app not found: $appId');
    return app;
  }

  // --- Helpers ---

  Future<Map<String, Object?>> _readJson(Request request) async {
    final text = await request.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw _HttpError(400, 'expected a JSON object');
    }
    return decoded;
  }

  Future<Uint8List> _readBytes(Request request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Uint8List _parseBundleId(String value) {
    final Uint8List bytes;
    try {
      bytes = _unhex(value.replaceAll('-', ''));
    } on FormatException {
      throw _HttpError(400, 'invalid bundle id: $value');
    }
    if (bytes.length != 16) throw _HttpError(400, 'bundle id must be 16 bytes');
    return bytes;
  }
}

/// Serves the operator dashboard (a self-contained HTML page). Read-only to
/// serve; every action it triggers goes through the authenticated /v1 API.
Response _dashboard(Request request) => Response.ok(
  dashboardHtml,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

/// The Ejenix logo, inlined in the binary. Unauthenticated on purpose — it is
/// the mark on the sign-in page, so it has to render before anyone has a key.
Response _brandLogo(Request request) => _asset(brandLogoPng, 'image/png');

/// The two typefaces the dashboard is set in, served from the binary for the
/// same reason as the logo: the page must render identically with no network
/// beyond this server. Both are SIL OFL — see THIRD_PARTY_NOTICES.md.
Response _brandInter(Request request) => _asset(brandInterWoff2, 'font/woff2');
Response _brandMono(Request request) =>
    _asset(brandJetBrainsMonoWoff2, 'font/woff2');

Response _asset(Uint8List bytes, String contentType) => Response.ok(
  bytes,
  headers: {
    'content-type': contentType,
    // Content-addressed by the binary that serves it: a new build is a new
    // server, so these can be cached hard.
    'cache-control': 'public, max-age=604800, immutable',
  },
);

Response _json(int status, Object? body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

/// Byte-wise equality, used to decide whether an upload is a re-publish of the
/// same release or an attempt to redefine one.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _validSlug(String id) =>
    RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(id);

/// Rejects any identifier that is not a plain slug, before it can reach a path.
///
/// The store interpolates app ids and environment names directly into
/// filenames (`envs/<app>/<env>.json`), so an unchecked `..` or `/` in either
/// escapes the app's own directory. The regex admits no separator, so a
/// traversal cannot survive it.
void _requireSlug(String value, String what) {
  if (!_validSlug(value)) throw _HttpError(400, 'invalid $what');
}

String _hex(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _unhex(String h) {
  if (h.length.isOdd) throw const FormatException('odd-length hex');
  return Uint8List.fromList([
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
}
