// Copyright (c) Ejenix authors. MIT license.

/// An **opt-in** network capability for interpreted patches.
///
/// Network access is deliberately *not* part of [flutterHostRegistry]. A patch
/// is code fetched over the air; if it could reach any URL by default, a
/// compromised update server could exfiltrate whatever the patch can see. So
/// this lives in its own library and takes two deliberate acts to enable — you
/// must import it *and* call [registerHttp] — and even then it is bounded:
///
/// * **HTTPS only.** Plaintext requests are refused.
/// * **Host allow-list.** Only the hosts you name are reachable; anything else
///   throws before a socket is opened.
/// * **GET only.** No mutation from a patch.
///
/// ```dart
/// InterpretedView(
///   module: module,
///   extend: (registry, _) =>
///       registerHttp(registry, allowedHosts: {'api.example.com'}),
/// )
/// ```
///
/// The stricter, preferred alternative is to expose the *specific* call you
/// need instead of a general fetch — `registry.registerGlobal('api.loadTodos',
/// (_, _) => api.loadTodos())` — which keeps the URL, auth, and retry policy in
/// the shipped binary where you control them. Reach for [registerHttp] only when
/// a patch genuinely needs open-ended reads.
library;

import 'package:http/http.dart' as http;
import 'package:ejenix_interpreter/interpreter.dart';

/// Thrown when a patch asks for a URL the host did not grant.
class HttpCapabilityDenied implements Exception {
  HttpCapabilityDenied(this.message);
  final String message;

  @override
  String toString() => 'HttpCapabilityDenied: $message';
}

/// Grants patches `httpGet(url)` — restricted to HTTPS on [allowedHosts].
///
/// Pass [client] to inject a stub in tests. The returned body is a [String]; a
/// patch parses it with `jsonDecode`, which is part of the core allow-list.
void registerHttp(
  HostRegistry registry, {
  required Set<String> allowedHosts,
  http.Client? client,
}) {
  final c = client ?? http.Client();

  registry.registerGlobal('httpGet', (_, args) async {
    final m = args.isEmpty
        ? const <Object?, Object?>{}
        : args[0] as Map<Object?, Object?>;
    final raw = m['url'] as String? ?? '';
    final uri = Uri.parse(raw);

    // Check before any socket is opened, and name the reason precisely: a
    // developer hitting this must know it is policy, not a network fault.
    if (uri.scheme != 'https') {
      throw HttpCapabilityDenied(
        'httpGet requires https, got `${uri.scheme.isEmpty ? raw : uri.scheme}`',
      );
    }
    if (!allowedHosts.contains(uri.host)) {
      throw HttpCapabilityDenied(
        'host `${uri.host}` is not in the allow-list '
        '(${allowedHosts.join(', ')})',
      );
    }

    final response = await c.get(uri);
    if (response.statusCode >= 400) {
      throw HttpCapabilityDenied(
        'GET ${uri.host}${uri.path} failed with ${response.statusCode}',
      );
    }
    return response.body;
  });
}
