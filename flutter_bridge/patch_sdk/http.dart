// Copyright (c) Ejenix authors. MIT license.

/// The **opt-in** network surface for a patch.
///
/// Import this only if the host app granted the capability by calling
/// `registerHttp(registry, allowedHosts: {...})` (see
/// `lib/ejenix_flutter_http.dart`). A patch that imports this against an app
/// that did not grant it compiles, then fails at the call with a clear error —
/// the sandbox denies what was never allowed.
///
/// Parse the body with `jsonDecode` from `dart:convert`, which is part of the
/// core allow-list (it is pure computation and crosses no boundary):
///
/// ```dart
/// import 'dart:convert';
/// import 'http.dart';
///
/// Future<String> firstTitle() async {
///   final body = await httpGet('https://api.example.com/todos');
///   return (jsonDecode(body) as List).first['title'] as String;
/// }
/// ```
library;

/// Fetches [url] over HTTPS. Restricted to the hosts the app allow-listed; any
/// other host, or a plaintext scheme, is refused before a socket opens.
external Future<String> httpGet(String url);
