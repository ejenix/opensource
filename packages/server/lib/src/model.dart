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
/// The channel used when a caller names none.
///
/// Every environment created before channels existed is this one, so the old
/// routes and every deployed device keep resolving to exactly what they did
/// before — no migration, no split fleet.
const String defaultChannel = 'default';

/// One patchable surface of an app, in one environment.
///
/// Keyed on `(appId, channel, name)`. The channel exists because an app has
/// more than one patchable screen, and keying only on `(appId, env)` meant
/// promoting one screen replaced whatever another had live.
class Env {
  Env({
    required this.appId,
    required this.name,
    this.channel = defaultChannel,
    this.activeBundleId,
    this.previousBundleId,
    this.rolloutPercent = 100,
    this.rolloutSalt = '',
  }) : assert(
         rolloutPercent >= 0 && rolloutPercent <= 100,
         'rolloutPercent must be 0..100',
       );

  final String appId;
  final String name;

  /// The patchable surface, e.g. `home`. [defaultChannel] when unnamed.
  final String channel;

  final Uint8List? activeBundleId;
  final Uint8List? previousBundleId;

  /// Share of the fleet that should take [activeBundleId], 0..100.
  ///
  /// The device decides whether it is inside this share, by hashing its own
  /// install id with [rolloutSalt]. The server never learns which devices
  /// exist — staged rollout costs no device registry and no telemetry.
  final int rolloutPercent;

  /// Fixed for the life of one promotion, so a device's bucket does not move.
  ///
  /// That is what makes widening additive: raising 5% to 20% only ever admits
  /// more devices, and never drops one that already had the patch.
  final String rolloutSalt;

  Map<String, Object?> toJson() => {
    'appId': appId,
    'name': name,
    'channel': channel,
    'activeBundleId': activeBundleId == null ? null : _hex(activeBundleId!),
    'previousBundleId': previousBundleId == null
        ? null
        : _hex(previousBundleId!),
    'rolloutPercent': rolloutPercent,
    'rolloutSalt': rolloutSalt,
  };

  static Env fromJson(Map<String, Object?> json) => Env(
    appId: json['appId'] as String,
    name: json['name'] as String,
    // Absent in records written before channels existed: they are all default.
    channel: json['channel'] as String? ?? defaultChannel,
    activeBundleId: json['activeBundleId'] == null
        ? null
        : _unhex(json['activeBundleId'] as String),
    previousBundleId: json['previousBundleId'] == null
        ? null
        : _unhex(json['previousBundleId'] as String),
    // Absent means "everyone", which is what a pre-rollout record meant.
    rolloutPercent: json['rolloutPercent'] as int? ?? 100,
    rolloutSalt: json['rolloutSalt'] as String? ?? '',
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
