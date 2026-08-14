// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The outcome of a fetch attempt.
sealed class FetchResult {
  const FetchResult();
}

/// The server reported the cached copy is still current (HTTP 304).
class FetchNotModified extends FetchResult {
  const FetchNotModified();
}

/// New bytes were fetched, with the server's entity tag if any.
class FetchSuccess extends FetchResult {
  const FetchSuccess(this.bytes, this.etag);
  final Uint8List bytes;
  final String? etag;
}

/// The fetch failed after exhausting retries.
class FetchFailure extends FetchResult {
  const FetchFailure(this.reason, {this.statusCode});
  final String reason;
  final int? statusCode;
}

/// Fetches bundle bytes from the configured control plane.
///
/// The loader talks to exactly one URL — the developer's control plane — and
/// this is the only network egress in the entire on-device stack (brief §6.6,
/// "no telemetry").
abstract interface class BundleFetcher {
  Future<FetchResult> fetch(Uri url, {String? etag});
}

/// An HTTPS [BundleFetcher] with conditional requests and jittered exponential
/// backoff.
///
/// Sends `If-None-Match` so an unchanged bundle costs one round trip and no
/// body. Transient failures (network errors, HTTP 5xx) are retried up to
/// [maxRetries] with exponentially increasing, jittered delays; 4xx responses
/// are returned immediately.
class HttpBundleFetcher implements BundleFetcher {
  HttpBundleFetcher({
    this.maxRetries = 3,
    this.timeout = const Duration(seconds: 30),
    this.baseBackoff = const Duration(milliseconds: 200),
    HttpClient Function()? clientFactory,
    Random? random,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _random = random ?? Random();

  final int maxRetries;
  final Duration timeout;
  final Duration baseBackoff;
  final HttpClient Function() _clientFactory;
  final Random _random;

  @override
  Future<FetchResult> fetch(Uri url, {String? etag}) async {
    var attempt = 0;
    while (true) {
      try {
        final result = await _attempt(url, etag);
        if (result is FetchFailure &&
            _isRetryable(result.statusCode) &&
            attempt < maxRetries) {
          attempt++;
          await _backoff(attempt);
          continue;
        }
        return result;
      } on Object catch (e) {
        if (attempt < maxRetries) {
          attempt++;
          await _backoff(attempt);
          continue;
        }
        return FetchFailure('network error: $e');
      }
    }
  }

  Future<FetchResult> _attempt(Uri url, String? etag) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(url);
      if (etag != null) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response = await request.close().timeout(timeout);
      switch (response.statusCode) {
        case 304:
          await response.drain<void>();
          return const FetchNotModified();
        case 200:
          final bytes = await _collect(response);
          return FetchSuccess(
            bytes,
            response.headers.value(HttpHeaders.etagHeader),
          );
        default:
          await response.drain<void>();
          return FetchFailure(
            'HTTP ${response.statusCode}',
            statusCode: response.statusCode,
          );
      }
    } finally {
      client.close(force: true);
    }
  }

  bool _isRetryable(int? statusCode) => statusCode == null || statusCode >= 500;

  Future<void> _backoff(int attempt) async {
    final base = baseBackoff.inMilliseconds * (1 << (attempt - 1));
    final jitter = _random.nextInt(base + 1);
    await Future<void>.delayed(Duration(milliseconds: base + jitter));
  }

  Future<Uint8List> _collect(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
