// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ejenix_bundle/bundle.dart';

import 'binary_delta.dart';

/// The body of a delta bundle: the id of the base it patches, the patch bytes,
/// and the SHA-256 the reconstructed target must hash to (brief §6.5).
class DeltaBody {
  const DeltaBody({
    required this.baseBundleId,
    required this.patch,
    required this.postPatchSha256,
  });

  /// The bundle id of the base this patch applies against.
  final Uint8List baseBundleId;

  /// The compressed binary patch.
  final Uint8List patch;

  /// The SHA-256 the patched-together target body must match before staging.
  final Uint8List postPatchSha256;

  /// Encodes the delta body as a positional CBOR array.
  Uint8List encode() =>
      (CborWriter()
            ..writeArrayHeader(3)
            ..writeBytes(baseBundleId)
            ..writeBytes(patch)
            ..writeBytes(postPatchSha256))
          .takeBytes();

  /// Decodes a delta body.
  static DeltaBody decode(Uint8List bytes) {
    final r = CborReader(bytes);
    if (r.readArrayHeader() != 3) {
      throw DeltaException('delta body must be a 3-element array');
    }
    return DeltaBody(
      baseBundleId: r.readBytes(),
      patch: r.readBytes(),
      postPatchSha256: r.readBytes(),
    );
  }
}

/// Builds and applies signed delta bundles.
///
/// A delta bundle reuses the full bundle envelope — same header and Ed25519
/// signature — with a [DeltaBody] payload instead of a module. It diffs the
/// *whole* base bundle bytes against the whole target bundle bytes, so applying
/// it reconstructs the complete, normally-signed target bundle, which then
/// verifies end-to-end on its own. The delta's signature protects the patch in
/// transit; the reconstructed target's signature provides end-to-end
/// authenticity (brief §6.5, §6.6).
class DeltaBundle {
  /// Creates a signed delta bundle transforming [base] into [target].
  static Bundle create({
    required Bundle base,
    required Bundle target,
    required Signer signer,
    required String compilerVersion,
    Uint8List? bundleId,
    int? createdAtMillis,
  }) {
    final baseBytes = base.encode();
    final targetBytes = target.encode();
    final body = DeltaBody(
      baseBundleId: base.bundleId,
      patch: BinaryDelta.computeDelta(baseBytes, targetBytes),
      postPatchSha256: Uint8List.fromList(sha256.convert(targetBytes).bytes),
    ).encode();
    return Bundle.signBytes(
      bodyBytes: body,
      signer: signer,
      compilerVersion: compilerVersion,
      bundleId: bundleId,
      createdAtMillis: createdAtMillis,
    );
  }

  /// Applies the delta in [deltaBundle] against [baseBundleBytes], returning the
  /// reconstructed full target bundle bytes.
  ///
  /// The caller must have already verified [deltaBundle]'s signature. This
  /// method checks that the reconstructed bytes match the declared post-patch
  /// hash, throwing [DeltaException] on mismatch. The caller then decodes and
  /// verifies the result as an ordinary bundle.
  static Uint8List apply(Bundle deltaBundle, Uint8List baseBundleBytes) {
    final delta = DeltaBody.decode(deltaBundle.bodyBytes);
    final target = BinaryDelta.applyDelta(baseBundleBytes, delta.patch);
    final actual = Uint8List.fromList(sha256.convert(target).bytes);
    if (!_bytesEqual(actual, delta.postPatchSha256)) {
      throw DeltaException('post-patch hash mismatch');
    }
    return target;
  }

  /// Whether [bundle]'s body is a delta payload (a 3-element CBOR array) rather
  /// than a module body (a 5-element array).
  static bool isDelta(Bundle bundle) {
    try {
      return CborReader(bundle.bodyBytes).readArrayHeader() == 3;
    } on Object {
      return false;
    }
  }

  /// The base bundle id a delta bundle patches against, read from its body.
  static Uint8List baseBundleIdOf(Bundle deltaBundle) =>
      DeltaBody.decode(deltaBundle.bodyBytes).baseBundleId;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
