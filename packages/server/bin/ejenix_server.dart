// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';
import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_server/server.dart';

/// Entry point for the control plane.
///
/// Configuration is via environment variables (12-factor):
///   EJENIX_ADMIN_KEY     required; bearer token for app administration
///   EJENIX_PORT          listen port (default 8080)
///   EJENIX_DATA_DIR      persistent data directory (default: in-memory)
///   EJENIX_DELIVERY_SEED 32-byte hex seed for the delta-signing key
Future<void> main() async {
  final adminKey = Platform.environment['EJENIX_ADMIN_KEY'];
  if (adminKey == null || adminKey.isEmpty) {
    stderr.writeln('EJENIX_ADMIN_KEY is required');
    exit(78); // EX_CONFIG
  }
  final port = int.tryParse(Platform.environment['EJENIX_PORT'] ?? '') ?? 8080;
  final dataDir = Platform.environment['EJENIX_DATA_DIR'];
  final store = dataDir == null
      ? InMemoryStore()
      : FileStore(Directory(dataDir)..createSync(recursive: true));

  // Blank counts as absent. Container platforms routinely pass an unset
  // variable through as an empty string — `${EJENIX_DELIVERY_SEED:-}` in a
  // compose file, an empty task-definition value — and a `== null` test then
  // sends "" to the signer, which dies with `ed25519: bad seed length 0` and
  // takes the whole server into a restart loop.
  final seedHex = Platform.environment['EJENIX_DELIVERY_SEED']?.trim();
  final Signer deliverySigner;
  if (seedHex == null || seedHex.isEmpty) {
    deliverySigner = Signer.generate();
    stdout.writeln(
      'EJENIX_DELIVERY_SEED is not set — using an ephemeral delivery key. '
      'Devices will stop trusting server-signed deltas after a restart; set a '
      'stable 32-byte hex seed before serving real traffic.',
    );
  } else {
    final Uint8List seed;
    try {
      seed = _unhex(seedHex);
    } on FormatException {
      stderr.writeln('EJENIX_DELIVERY_SEED is not valid hex.');
      exit(78); // EX_CONFIG
    }
    if (seed.length != 32) {
      stderr.writeln(
        'EJENIX_DELIVERY_SEED must be 32 bytes (64 hex characters), '
        'got ${seed.length}.',
      );
      exit(78);
    }
    deliverySigner = Signer.fromSeed(seed);
  }

  final plane = ControlPlane(
    store: store,
    adminApiKey: adminKey,
    deliverySigner: deliverySigner,
    logSink: (entry) => stdout.writeln(_jsonLine(entry)),
  );

  final server = await serve(plane, address: '0.0.0.0', port: port);
  stdout.writeln('control plane listening on :${server.port}');
  stdout.writeln('delivery public key: ${_hex(deliverySigner.publicKey)}');
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _unhex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String _jsonLine(Map<String, Object?> entry) {
  final parts = [
    for (final e in entry.entries) '"${e.key}":${_encode(e.value)}',
  ];
  return '{${parts.join(',')}}';
}

String _encode(Object? value) => switch (value) {
  null => 'null',
  final num n => '$n',
  final bool b => '$b',
  _ => '"$value"',
};
