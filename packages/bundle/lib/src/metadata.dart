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
  });

  /// The application this bundle targets (e.g. `com.example.app`).
  final String targetAppId;

  /// The Flutter version the bundle was built against.
  final String targetFlutterVersion;

  /// The minimum interpreter SDK version required to run the bundle.
  final String minSdk;

  @override
  bool operator ==(Object other) =>
      other is BundleMetadata &&
      other.targetAppId == targetAppId &&
      other.targetFlutterVersion == targetFlutterVersion &&
      other.minSdk == minSdk;

  @override
  int get hashCode => Object.hash(targetAppId, targetFlutterVersion, minSdk);
}
