// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:io';

import 'base_command.dart';

/// A minimal HTTP client for the control-plane API, used by the `publish`,
/// `promote`, and `rollback` commands. Errors are surfaced as [CliException]s
/// with sysexits codes (69 unavailable, 70 software).
class ControlPlaneClient {
  ControlPlaneClient({required this.server, this.appId, required this.token});

  final String server;

  /// The app the app-scoped calls act on. Not needed for [createApp]/[listApps]
  /// (which use the admin token against the collection endpoint).
  final String? appId;
  final String token;

  Uri _uri(String path) => Uri.parse('$server/v1/apps/$appId/$path');
  Uri get _appsUri => Uri.parse('$server/v1/apps');

  /// Registers a new app with the [id] and the [trustedKeys] (hex) whose
  /// signatures its patches must carry. Requires the admin token; the response
  /// includes the app's API key, shown once.
  Future<Map<String, Object?>> createApp({
    required String id,
    required List<String> trustedKeys,
    String? name,
  }) => _send(
    'POST',
    _appsUri,
    json: {
      'id': id,
      if (name != null) 'name': name,
      'trustedKeys': trustedKeys,
    },
  );

  /// Lists the registered apps. Requires the admin token.
  Future<Map<String, Object?>> listApps() => _send('GET', _appsUri);

  /// Uploads [bundleBytes] to the app's bundle collection.
  Future<Map<String, Object?>> publish(List<int> bundleBytes) =>
      _send('POST', _uri('bundles'), bodyBytes: bundleBytes);

  /// Promotes [bundleId] to become active in [env].
  Future<Map<String, Object?>> setActive(String env, String bundleId) =>
      _send('POST', _uri('envs/$env/active'), json: {'bundleId': bundleId});

  /// Rolls [env] back to its previously active bundle.
  Future<Map<String, Object?>> rollback(String env) =>
      _send('POST', _uri('envs/$env/rollback'));

  Future<Map<String, Object?>> _send(
    String method,
    Uri uri, {
    List<int>? bodyBytes,
    Map<String, Object?>? json,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(json)));
      } else if (bodyBytes != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/octet-stream',
        );
        request.add(bodyBytes);
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      if (response.statusCode >= 400) {
        throw CliException(
          'control plane returned ${response.statusCode}: ${_error(text)}',
          exitCode: 70,
        );
      }
      return text.isEmpty ? {} : jsonDecode(text) as Map<String, Object?>;
    } on SocketException catch (e) {
      throw CliException('cannot reach $server: ${e.message}', exitCode: 69);
    } finally {
      client.close(force: true);
    }
  }

  String _error(String body) {
    try {
      return (jsonDecode(body) as Map)['error']?.toString() ?? body;
    } on FormatException {
      return body;
    }
  }
}
