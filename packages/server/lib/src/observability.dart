// Copyright (c) Ejenix authors. MIT license.

import 'dart:math';

import 'package:shelf/shelf.dart';

/// An in-process metrics registry rendered in Prometheus text-exposition format
/// (brief §6.8). Deliberately small: request counts and a latency histogram per
/// route, plus bundle-upload and activation counters. No user analytics.
class Metrics {
  final Map<String, int> _counters = {};
  final Map<String, _Histogram> _histograms = {};

  static const List<double> _latencyBuckets = [
    0.005,
    0.01,
    0.025,
    0.05,
    0.1,
    0.25,
    0.5,
    1,
    2.5,
    5,
  ];

  void recordRequest(String method, String route, int status, double seconds) {
    _counters.update(
      'ejenix_requests_total{method="$method",route="$route",'
      'status="$status"}',
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    (_histograms['ejenix_request_duration_seconds{route="$route"}'] ??=
            _Histogram(_latencyBuckets))
        .observe(seconds);
  }

  void recordUpload(int bytes) {
    _counters.update(
      'ejenix_bundle_uploads_total',
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    _counters.update(
      'ejenix_bundle_upload_bytes_total',
      (v) => v + bytes,
      ifAbsent: () => bytes,
    );
  }

  void recordActivation(String env) {
    _counters.update(
      'ejenix_activations_total{env="$env"}',
      (v) => v + 1,
      ifAbsent: () => 1,
    );
  }

  /// Renders the registry in Prometheus text format.
  String render() {
    final buffer = StringBuffer();
    for (final entry in _counters.entries) {
      buffer.writeln('${entry.key} ${entry.value}');
    }
    for (final entry in _histograms.entries) {
      entry.value.render(entry.key, buffer);
    }
    return buffer.toString();
  }
}

class _Histogram {
  _Histogram(this.bounds) : counts = List.filled(bounds.length, 0);
  final List<double> bounds;
  final List<int> counts;
  int total = 0;
  double sum = 0;

  void observe(double value) {
    total++;
    sum += value;
    for (var i = 0; i < bounds.length; i++) {
      if (value <= bounds[i]) counts[i]++;
    }
  }

  void render(String key, StringBuffer buffer) {
    // key is like `name{route="x"}`; splice `le` into the label set.
    final open = key.indexOf('{');
    final name = key.substring(0, open);
    final labels = key.substring(open + 1, key.length - 1);
    for (var i = 0; i < bounds.length; i++) {
      buffer.writeln('${name}_bucket{$labels,le="${bounds[i]}"} ${counts[i]}');
    }
    buffer.writeln('${name}_bucket{$labels,le="+Inf"} $total');
    buffer.writeln('${name}_sum{$labels} $sum');
    buffer.writeln('${name}_count{$labels} $total');
  }
}

/// Wraps a handler with a request id, structured JSON access logging, and
/// metrics. The request id is echoed as `X-Request-Id`. Logs go to [logSink]
/// (defaulting to nowhere in tests); there is no external reporting.
Middleware observability({
  required Metrics metrics,
  void Function(Map<String, Object?> entry)? logSink,
  Random? random,
}) {
  final rng = random ?? Random();
  return (Handler inner) {
    return (Request request) async {
      final requestId = _requestId(rng);
      final watch = Stopwatch()..start();
      final response = await inner(
        request.change(context: {'requestId': requestId}),
      );
      watch.stop();

      final route = _routeLabel(request.url.path);
      final seconds = watch.elapsedMicroseconds / 1e6;
      metrics.recordRequest(
        request.method,
        route,
        response.statusCode,
        seconds,
      );

      logSink?.call({
        'level': response.statusCode >= 500 ? 'error' : 'info',
        'ts': DateTime.now().toUtc().toIso8601String(),
        'requestId': requestId,
        'method': request.method,
        'path': '/${request.url.path}',
        'status': response.statusCode,
        'latencyMs': watch.elapsedMicroseconds / 1000,
        'userAgent': request.headers['user-agent'],
      });

      return response.change(headers: {'X-Request-Id': requestId});
    };
  };
}

String _requestId(Random rng) => [
  for (var i = 0; i < 8; i++)
    rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// Collapses id-bearing path segments so routes aggregate in metrics (e.g.
/// `v1/apps/acme/bundles/ab12.bundle` -> `v1/apps/:app/bundles/:id`).
String _routeLabel(String path) {
  final segments = path.split('/');
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    if (i > 0 && (segments[i - 1] == 'apps' && i == 2)) {
      segments[i] = ':app';
    } else if (s.endsWith('.bundle') || _looksLikeId(s)) {
      segments[i] = ':id';
    }
  }
  return segments.join('/');
}

bool _looksLikeId(String s) =>
    s.length >= 8 && RegExp(r'^[0-9a-f]+$').hasMatch(s);
