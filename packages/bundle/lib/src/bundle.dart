// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ejenix_bytecode/bytecode.dart';

import 'cbor.dart';
import 'metadata.dart';
import 'module_codec.dart';
import 'signing.dart';
import 'uuid.dart';

/// The 4-byte format magic, "INTP".
final Uint8List bundleMagic = Uint8List.fromList([0x49, 0x4E, 0x54, 0x50]);

/// Raised when bundle bytes are structurally malformed (not merely unverified).
class BundleFormatException implements Exception {
  BundleFormatException(this.message);
  final String message;
  @override
  String toString() => 'BundleFormatException: $message';
}

/// The set of public keys a verifier trusts.
class TrustAnchors {
  TrustAnchors(this.keys);

  /// A trust set containing a single [key].
  factory TrustAnchors.single(Uint8List key) => TrustAnchors([key]);

  final List<Uint8List> keys;

  /// Whether [key] is trusted.
  bool contains(Uint8List key) => keys.any((k) => _bytesEqual(k, key));
}

/// A specific reason bundle verification failed.
enum BundleFailure {
  badMagic,
  incompatibleVersion,
  bodyHashMismatch,
  badSignature,
  untrustedKey,
}

/// The result of [Bundle.verify].
class BundleVerification {
  const BundleVerification.ok() : failure = null;
  const BundleVerification.failed(this.failure);

  /// The failure reason, or `null` if verification passed.
  final BundleFailure? failure;

  /// Whether the bundle is valid.
  bool get isValid => failure == null;

  @override
  String toString() =>
      isValid ? 'BundleVerification.ok' : 'BundleVerification($failure)';
}

/// A signed, verifiable, self-describing unit of delivery (brief §6.4).
///
/// The signature covers the header bytes, which commit to the body via its
/// SHA-256. Verification recomputes the body hash and checks the Ed25519
/// signature against a trust anchor, in that strict order.
class Bundle {
  Bundle._({
    required this.magic,
    required this.versionMajor,
    required this.versionMinor,
    required this.bundleId,
    required this.createdAtMillis,
    required this.compilerVersion,
    required this.bodySha256,
    required this.publicKey,
    required this.signature,
    required this.bodyBytes,
    required this.headerBytes,
  });

  final Uint8List magic;
  final int versionMajor;
  final int versionMinor;
  final Uint8List bundleId;
  final int createdAtMillis;
  final String compilerVersion;
  final Uint8List bodySha256;
  final Uint8List publicKey;
  final Uint8List signature;
  final Uint8List bodyBytes;

  /// The exact signed header bytes. Retained so signature verification uses the
  /// original encoding, never a re-encoding.
  final Uint8List headerBytes;

  /// Builds and signs a bundle for [module] and [metadata].
  static Bundle sign({
    required Module module,
    required BundleMetadata metadata,
    required Signer signer,
    required String compilerVersion,
    Uint8List? bundleId,
    int? createdAtMillis,
  }) {
    return signBytes(
      bodyBytes: ModuleCodec.encodeBody(module, metadata),
      signer: signer,
      compilerVersion: compilerVersion,
      bundleId: bundleId,
      createdAtMillis: createdAtMillis,
    );
  }

  /// Builds and signs a bundle over arbitrary [bodyBytes].
  ///
  /// The header and signature are identical in form to a module bundle; only
  /// the body differs. This is what a delta bundle uses — same envelope, a
  /// patch payload instead of a module (brief §6.5).
  static Bundle signBytes({
    required Uint8List bodyBytes,
    required Signer signer,
    required String compilerVersion,
    Uint8List? bundleId,
    int? createdAtMillis,
  }) {
    final id = bundleId ?? uuidV7();
    final createdAt = createdAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final bodyHash = Uint8List.fromList(sha256.convert(bodyBytes).bytes);
    final headerBytes = _encodeHeader(id, createdAt, compilerVersion, bodyHash);
    return Bundle._(
      magic: Uint8List.fromList(bundleMagic),
      versionMajor: 1,
      versionMinor: 0,
      bundleId: id,
      createdAtMillis: createdAt,
      compilerVersion: compilerVersion,
      bodySha256: bodyHash,
      publicKey: signer.publicKey,
      signature: signer.sign(headerBytes),
      bodyBytes: bodyBytes,
      headerBytes: headerBytes,
    );
  }

  /// Decodes the module and metadata from this bundle's body.
  (Module, BundleMetadata) decodeBody() => ModuleCodec.decodeBody(bodyBytes);

  /// Verifies this bundle in strict order, returning the first failure
  /// encountered: magic, version, body hash, signature, then trust anchor.
  ///
  /// [anchors] is the set of trusted signing keys.
  BundleVerification verify({required TrustAnchors anchors}) {
    if (!_bytesEqual(magic, bundleMagic)) {
      return const BundleVerification.failed(BundleFailure.badMagic);
    }
    if (versionMajor != 1) {
      return const BundleVerification.failed(BundleFailure.incompatibleVersion);
    }
    final recomputed = Uint8List.fromList(sha256.convert(bodyBytes).bytes);
    if (!_bytesEqual(recomputed, bodySha256)) {
      return const BundleVerification.failed(BundleFailure.bodyHashMismatch);
    }
    if (!verifySignature(publicKey, headerBytes, signature)) {
      return const BundleVerification.failed(BundleFailure.badSignature);
    }
    if (!anchors.contains(publicKey)) {
      return const BundleVerification.failed(BundleFailure.untrustedKey);
    }
    return const BundleVerification.ok();
  }

  /// Serializes the whole bundle to canonical CBOR bytes:
  /// `[header, publicKey, signature, body]`.
  Uint8List encode() {
    return (CborWriter()
          ..writeArrayHeader(4)
          ..writeBytes(headerBytes)
          ..writeBytes(publicKey)
          ..writeBytes(signature)
          ..writeBytes(bodyBytes))
        .takeBytes();
  }

  /// Parses bundle [bytes]. Throws [BundleFormatException] if the byte layout is
  /// malformed; cryptographic validity is a separate concern for [verify].
  static Bundle decode(Uint8List bytes) {
    try {
      return _decode(bytes);
    } on CborException catch (e) {
      throw BundleFormatException(e.message);
    }
  }

  static Bundle _decode(Uint8List bytes) {
    final r = CborReader(bytes);
    if (r.readArrayHeader() != 4) {
      throw BundleFormatException('bundle must be a 4-element array');
    }
    final headerBytes = r.readBytes();
    final publicKey = r.readBytes();
    final signature = r.readBytes();
    final bodyBytes = r.readBytes();

    final hr = CborReader(headerBytes);
    if (hr.readArrayHeader() != 7) {
      throw BundleFormatException('header must be a 7-element array');
    }
    final magic = hr.readBytes();
    final versionMajor = hr.readInt();
    final versionMinor = hr.readInt();
    final bundleId = hr.readBytes();
    final createdAt = hr.readInt();
    final compilerVersion = hr.readString();
    final bodyHash = hr.readBytes();

    return Bundle._(
      magic: magic,
      versionMajor: versionMajor,
      versionMinor: versionMinor,
      bundleId: bundleId,
      createdAtMillis: createdAt,
      compilerVersion: compilerVersion,
      bodySha256: bodyHash,
      publicKey: publicKey,
      signature: signature,
      bodyBytes: bodyBytes,
      headerBytes: headerBytes,
    );
  }

  static Uint8List _encodeHeader(
    Uint8List id,
    int createdAt,
    String compilerVersion,
    Uint8List bodyHash,
  ) {
    return (CborWriter()
          ..writeArrayHeader(7)
          ..writeBytes(bundleMagic)
          ..writeInt(1)
          ..writeInt(0)
          ..writeBytes(id)
          ..writeInt(createdAt)
          ..writeString(compilerVersion)
          ..writeBytes(bodyHash))
        .takeBytes();
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
