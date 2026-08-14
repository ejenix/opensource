// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';

/// Resolves the **active** bundle for an app/environment on a control plane, so
/// a [Loader] can be pointed at it with a plain download URL.
///
/// The device flow is two hops: ask which bundle is active for the environment
/// (`GET /v1/apps/<app>/envs/<env>/active`), then hand the resulting download URL
/// to [Loader.checkForUpdate], which fetches it with an ETag and stages it. This
/// client only *reads* the active pointer — publishing and promoting are the
/// CLI's job — so it is safe to embed in a shipped app.
///
/// It is read-only and fail-soft: any network or protocol error resolves to
/// `null` (no active bundle known), so a control plane being unreachable never
/// throws into your UI — the app simply keeps running the patch it already has.
///
/// Uses `dart:io` `HttpClient` directly (no `package:http`), matching
/// [HttpBundleFetcher]; pass [clientFactory] to inject a client in tests.
class ControlPlaneClient {
  ControlPlaneClient({
    required this.base,
    required this.appId,
    this.env = 'production',
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  /// The control-plane origin, e.g. `Uri.parse('https://patches.myapp.com')`.
  /// A path prefix (`https://host/ejenix`) is preserved.
  final Uri base;

  /// The app id registered on the control plane. A bundle must target it.
  final String appId;

  /// The environment to track (e.g. `production`, `staging`).
  final String env;

  final Duration timeout;
  final HttpClient Function() _clientFactory;

  /// The id of the bundle currently active for [env], or `null` if there is
  /// none or the control plane could not be reached.
  Future<String?> activeBundleId() async {
    final client = _clientFactory();
    try {
      final request = await client
          .getUrl(_api(['envs', env, 'active']))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is Map && json['activeBundleId'] is String) {
        return json['activeBundleId'] as String;
      }
      return null;
    } on Object {
      // Unreachable, timed out, or malformed — treat as "no update available".
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The download URL for [bundleId], to pass to [Loader.checkForUpdate].
  Uri downloadUrl(String bundleId) => _api(['bundles', '$bundleId.bundle']);

  /// Builds `<base>/v1/apps/<app>/<segments…>`, preserving any base path prefix
  /// and tolerating a trailing slash on [base].
  Uri _api(List<String> segments) => base.replace(
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      'v1',
      'apps',
      appId,
      ...segments,
    ],
  );
}
