// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_delta/delta.dart';

import 'bundle_store.dart';
import 'fetcher.dart';
import 'host_environment.dart';

/// The result of [Loader.checkForUpdate].
sealed class UpdateOutcome {
  const UpdateOutcome();
}

/// The server had no newer bundle.
class UpToDate extends UpdateOutcome {
  const UpToDate();
}

/// A verified, compatible bundle was staged, ready to activate.
class Staged extends UpdateOutcome {
  const Staged(this.bundleId);
  final Uint8List bundleId;
}

/// The bundle was fetched but rejected (bad signature, wrong app, etc.).
class Rejected extends UpdateOutcome {
  const Rejected(this.reason);
  final String reason;
}

/// The bundle could not be fetched.
class FetchError extends UpdateOutcome {
  const FetchError(this.reason);
  final String reason;
}

/// Drives the device-side update lifecycle: fetch, verify, stage, activate, and
/// crash-loop rollback (brief §6.6).
///
/// The verification order is strict and stops at the first failure: signature
/// and content integrity via [Bundle.verify], then host/metadata compatibility.
/// A fetched delta is applied against the cached active bundle and the
/// reconstructed target is verified as an ordinary bundle. The loader performs
/// no analytics or error reporting; its only network egress is [fetcher].
class Loader {
  Loader({
    required this.store,
    required this.fetcher,
    required this.anchors,
    required this.host,
  });

  final BundleStore store;
  final BundleFetcher fetcher;
  final TrustAnchors anchors;
  final HostEnvironment host;

  /// Verifies and stages a bundle you already hold the [bytes] for — e.g. the
  /// patch that shipped as an app asset — without any network fetch. Runs the
  /// same strict verification and compatibility checks as [checkForUpdate].
  UpdateOutcome ingest(Uint8List bytes) => _ingest(bytes);

  /// Fetches from [url] and, if a newer valid bundle is available, stages it.
  Future<UpdateOutcome> checkForUpdate(Uri url) async {
    final result = await fetcher.fetch(url, etag: store.lastEtag);
    switch (result) {
      case FetchNotModified():
        return const UpToDate();
      case FetchFailure(:final reason):
        return FetchError(reason);
      case FetchSuccess(:final bytes, :final etag):
        final outcome = _ingest(bytes);
        if (outcome is Staged) store.lastEtag = etag;
        return outcome;
    }
  }

  UpdateOutcome _ingest(Uint8List bytes) {
    final Bundle bundle;
    try {
      bundle = Bundle.decode(bytes);
    } on BundleFormatException catch (e) {
      return Rejected('malformed bundle: ${e.message}');
    }

    final verification = bundle.verify(anchors: anchors);
    if (!verification.isValid) {
      return Rejected('verification failed: ${verification.failure}');
    }

    // A delta must be resolved against the cached active bundle first.
    if (DeltaBundle.isDelta(bundle)) {
      return _ingestDelta(bundle);
    }
    return _stageModuleBundle(bundle);
  }

  UpdateOutcome _ingestDelta(Bundle deltaBundle) {
    final baseBytes = store.activeBundleBytes;
    if (baseBytes == null) {
      return const Rejected('received a delta but no base bundle is active');
    }
    final base = store.activeBundle!;
    if (!_bytesEqual(DeltaBundle.baseBundleIdOf(deltaBundle), base.bundleId)) {
      return const Rejected('delta base id does not match the active bundle');
    }
    final Uint8List targetBytes;
    try {
      targetBytes = DeltaBundle.apply(deltaBundle, baseBytes);
    } on DeltaException catch (e) {
      return Rejected('delta apply failed: ${e.message}');
    }
    final Bundle target;
    try {
      target = Bundle.decode(targetBytes);
    } on BundleFormatException catch (e) {
      return Rejected('reconstructed bundle malformed: ${e.message}');
    }
    // The reconstructed target must independently verify.
    final verification = target.verify(anchors: anchors);
    if (!verification.isValid) {
      return Rejected('reconstructed bundle failed: ${verification.failure}');
    }
    return _stageModuleBundle(target);
  }

  UpdateOutcome _stageModuleBundle(Bundle bundle) {
    final BundleMetadata metadata;
    try {
      final (_, decoded) = bundle.decodeBody();
      metadata = decoded;
    } on CborException catch (e) {
      return Rejected('body decode failed: ${e.message}');
    }
    final compatibility = host.isCompatible(metadata);
    if (!compatibility.isCompatible) {
      return Rejected('incompatible: ${compatibility.reason}');
    }
    store.writeStaging(bundle);
    return Staged(bundle.bundleId);
  }

  /// Activates a previously staged bundle by [bundleId].
  bool activate(Uint8List bundleId) => store.activate(bundleId);

  /// Manually reverts to the previous bundle. Returns whether a revert happened.
  bool rollback() => store.rollback();

  /// Runs the startup rollback guard. Call once, early, at process start:
  /// records the launch and, if the active bundle is crash-looping, reverts to
  /// the previous one. Returns whether a rollback occurred.
  bool guardStartup() {
    store.recordLaunch();
    if (store.shouldAutoRollback()) {
      return store.rollback();
    }
    return false;
  }

  /// Marks the current run healthy, resetting the crash-loop counter. Call once
  /// the app has confirmed a good startup.
  void markHealthy() => store.markHealthy();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
