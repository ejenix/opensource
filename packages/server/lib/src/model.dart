// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

/// A registered application.
///
/// [apiKeyHash] is the SHA-256 of the app's bearer token; the token itself is
/// returned once at creation and never stored. [trustedKeys] are the Ed25519
/// public keys whose signatures the control plane will accept for this app's
/// bundles.
class App {
  App({
    required this.id,
    required this.name,
    required this.apiKeyHash,
    required this.trustedKeys,
    required this.createdAtMillis,
  });

  final String id;
  final String name;
  final String apiKeyHash;
  final List<Uint8List> trustedKeys;
  final int createdAtMillis;

  /// A public view without the key hash.
  Map<String, Object?> toPublicJson() => {
    'id': id,
    'name': name,
    'trustedKeys': [for (final k in trustedKeys) _hex(k)],
    'createdAtMillis': createdAtMillis,
  };

  Map<String, Object?> toJson() => {
    ...toPublicJson(),
    'apiKeyHash': apiKeyHash,
  };

  static App fromJson(Map<String, Object?> json) => App(
    id: json['id'] as String,
    name: json['name'] as String,
    apiKeyHash: json['apiKeyHash'] as String,
    trustedKeys: [
      for (final k in json['trustedKeys'] as List) _unhex(k as String),
    ],
    createdAtMillis: (json['createdAtMillis'] as num).toInt(),
  );
}

/// A deployment environment (e.g. `dev`, `staging`, `production`) and the
/// bundle currently active in it.
class Env {
  Env({
    required this.appId,
    required this.name,
    this.activeBundleId,
    this.previousBundleId,
  });

  final String appId;
  final String name;
  final Uint8List? activeBundleId;
  final Uint8List? previousBundleId;

  Map<String, Object?> toJson() => {
    'appId': appId,
    'name': name,
    'activeBundleId': activeBundleId == null ? null : _hex(activeBundleId!),
    'previousBundleId': previousBundleId == null
        ? null
        : _hex(previousBundleId!),
  };

  static Env fromJson(Map<String, Object?> json) => Env(
    appId: json['appId'] as String,
    name: json['name'] as String,
    activeBundleId: json['activeBundleId'] == null
        ? null
        : _unhex(json['activeBundleId'] as String),
    previousBundleId: json['previousBundleId'] == null
        ? null
        : _unhex(json['previousBundleId'] as String),
  );
}

/// A stored bundle's metadata (not its bytes).
class BundleRef {
  BundleRef({
    required this.bundleId,
    required this.sizeBytes,
    required this.uploadedAtMillis,
  });

  final Uint8List bundleId;
  final int sizeBytes;
  final int uploadedAtMillis;

  Map<String, Object?> toJson() => {
    'bundleId': _hex(bundleId),
    'sizeBytes': sizeBytes,
    'uploadedAtMillis': uploadedAtMillis,
  };

  static BundleRef fromJson(Map<String, Object?> json) => BundleRef(
    bundleId: _unhex(json['bundleId'] as String),
    sizeBytes: (json['sizeBytes'] as num).toInt(),
    uploadedAtMillis: (json['uploadedAtMillis'] as num).toInt(),
  );
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _unhex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);
