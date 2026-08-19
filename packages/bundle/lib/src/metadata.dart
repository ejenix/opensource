// Copyright (c) Ejenix authors. MIT license.

/// Compatibility metadata carried in a bundle body (brief §6.4).
///
/// The loader checks these against the host app before staging a bundle, so a
/// patch built for one app or an incompatible runtime is rejected rather than
/// executed.
class BundleMetadata {
  const BundleMetadata({
    required this.targetAppId,
    required this.targetFlutterVersion,
    required this.minSdk,
    this.releaseGeneration = 0,
  });

  /// The application this bundle targets (e.g. `com.example.app`).
  final String targetAppId;

  /// The Flutter version the bundle was built against.
  final String targetFlutterVersion;

  /// The minimum interpreter SDK version required to run the bundle.
  final String minSdk;

  /// A number that only ever increases across the releases you publish.
  ///
  /// A device records the highest generation it has accepted and refuses
  /// anything lower. Without it, a compromised or merely stale control plane
  /// can re-serve an *old but validly signed* release — the signature is
  /// genuine, so every cryptographic check passes, and a fixed vulnerability
  /// comes back. Signing proves authorship; it says nothing about recency.
  ///
  /// `0` means "unversioned": bundles built before this field existed carry it,
  /// and a device applies no freshness rule to them, exactly as before.
  final int releaseGeneration;

  @override
  bool operator ==(Object other) =>
      other is BundleMetadata &&
      other.targetAppId == targetAppId &&
      other.targetFlutterVersion == targetFlutterVersion &&
      other.minSdk == minSdk;

  @override
  int get hashCode => Object.hash(targetAppId, targetFlutterVersion, minSdk);
}
