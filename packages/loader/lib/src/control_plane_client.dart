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
    this.channel = 'default',
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

  /// The patchable surface this view follows — one screen of the app.
  ///
  /// `default` uses the pre-channel route, so a new client still works against
  /// a control plane that predates channels.
  final String channel;

  final Duration timeout;
  final HttpClient Function() _clientFactory;

  /// The id of the bundle currently active for [env], or `null` if there is
  /// none, this install is outside a staged rollout, or the control plane
  /// could not be reached.
  ///
  /// [installId] is this device's stable local identifier. It is used only to
  /// evaluate a staged rollout locally and is never transmitted.
  Future<String?> activeBundleId({String? installId}) async {
    final client = _clientFactory();
    try {
      final request = await client
          .getUrl(_api([...(_channelSegments), 'envs', env, 'active']))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map || json['activeBundleId'] is! String) return null;

      // Staged rollout is decided here, on the device. The server publishes a
      // share and a salt; it never learns which installs took the bundle.
      final percent = json['rolloutPercent'];
      if (percent is int && percent < 100) {
        final salt = json['rolloutSalt'] as String? ?? '';
        if (!isInRollout(
          installId: installId ?? '',
          salt: salt,
          percent: percent,
        )) {
          return null; // Outside the share — behave as "nothing new".
        }
      }
      return json['activeBundleId'] as String;
    } on Object {
      // Unreachable, timed out, or malformed — treat as "no update available".
      return null;
    } finally {
      client.close(force: true);
    }
  }

  List<String> get _channelSegments =>
      channel == 'default' ? const [] : ['channels', channel];

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

/// Whether an install falls inside a staged rollout.
///
/// Deliberately a pure function of (install id, salt, percent):
///
/// * **Local.** The device answers for itself, so staged rollout needs no
///   device registry, no telemetry, and no way for the control plane to target
///   one install.
/// * **Stable.** The same inputs always give the same answer, so a device does
///   not drift in and out of a rollout between launches.
/// * **Monotonic.** The salt is fixed for the life of a promotion, so raising
///   the percentage only ever admits more devices — it never drops one that
///   already had the patch.
///
/// FNV-1a is used because it is tiny, dependency-free, and well distributed for
/// short strings. It is not a security primitive and does not need to be: the
/// bucket decides presentation, never trust. Signature verification is what
/// decides whether bytes may run.
bool isInRollout({
  required String installId,
  required String salt,
  required int percent,
}) {
  if (percent >= 100) return true;
  if (percent <= 0) return false;
  // An install with no id yet cannot be bucketed stably; treat it as outside so
  // a canary never reaches a device we cannot keep consistent across launches.
  if (installId.isEmpty) return false;
  var hash = 0x811c9dc5;
  for (final unit in '$installId:$salt'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash % 100 < percent;
}
