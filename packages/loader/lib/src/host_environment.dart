// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bundle/bundle.dart';

/// The result of a metadata compatibility check.
class CompatibilityResult {
  const CompatibilityResult.ok() : reason = null;
  const CompatibilityResult.incompatible(this.reason);

  /// Why the bundle is incompatible, or `null` if it is compatible.
  final String? reason;

  /// Whether the bundle may run on this host.
  bool get isCompatible => reason == null;
}

/// The host application's identity and runtime, checked against a bundle's
/// [BundleMetadata] before staging (brief §6.6 step 5).
///
/// This is verification step 5 — metadata compatibility — which lives in the
/// loader rather than the bundle verifier because only the host knows its own
/// identity and runtime versions.
class HostEnvironment {
  const HostEnvironment({
    required this.appId,
    required this.flutterVersion,
    required this.sdkVersion,
  });

  /// The host application id. A bundle must target exactly this app.
  final String appId;

  /// The host's Flutter version.
  final String flutterVersion;

  /// The interpreter SDK version on this device. Must be at least the bundle's
  /// declared minimum.
  final String sdkVersion;

  /// Checks [metadata] for compatibility with this host.
  CompatibilityResult isCompatible(BundleMetadata metadata) {
    if (metadata.targetAppId != appId) {
      return CompatibilityResult.incompatible(
        'bundle targets app "${metadata.targetAppId}" but host is "$appId"',
      );
    }
    if (_compareSemver(sdkVersion, metadata.minSdk) < 0) {
      return CompatibilityResult.incompatible(
        'host SDK $sdkVersion is below the bundle minimum ${metadata.minSdk}',
      );
    }
    return const CompatibilityResult.ok();
  }
}

/// Compares dotted numeric versions (`major.minor.patch`). Missing components
/// are treated as zero; any non-numeric suffix is ignored.
int _compareSemver(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);
  for (var i = 0; i < 3; i++) {
    final cmp = pa[i].compareTo(pb[i]);
    if (cmp != 0) return cmp;
  }
  return 0;
}

List<int> _parse(String v) {
  final parts = v.split('.');
  return [
    for (var i = 0; i < 3; i++)
      i < parts.length ? (int.tryParse(_leadingDigits(parts[i])) ?? 0) : 0,
  ];
}

String _leadingDigits(String s) {
  final match = RegExp(r'^\d+').firstMatch(s);
  return match?.group(0) ?? '0';
}
