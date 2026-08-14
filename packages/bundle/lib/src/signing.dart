// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// An Ed25519 private key used to sign bundles (RFC 8032).
///
/// The signing key stays local to the developer's machine (brief §6.4). It is
/// stored and transported as its 32-byte seed; the full expanded private key is
/// derived on load.
class Signer {
  Signer._(this._private);

  final ed.PrivateKey _private;

  /// Generates a fresh key pair from a cryptographically secure seed.
  factory Signer.generate() => Signer._(ed.generateKey().privateKey);

  /// Reconstructs a signer from a 32-byte [seed].
  factory Signer.fromSeed(Uint8List seed) => Signer._(ed.newKeyFromSeed(seed));

  /// The 32-byte public key.
  Uint8List get publicKey => Uint8List.fromList(ed.public(_private).bytes);

  /// The 32-byte seed — the portable, storable form of the private key.
  Uint8List get seed => ed.seed(_private);

  /// Signs [message], returning a 64-byte signature.
  Uint8List sign(Uint8List message) => ed.sign(_private, message);
}

/// Verifies that [signature] is a valid Ed25519 signature of [message] under the
/// 32-byte [publicKey]. Returns `false` on any malformed input rather than
/// throwing, so it is safe to call on untrusted data.
bool verifySignature(
  Uint8List publicKey,
  Uint8List message,
  Uint8List signature,
) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  try {
    return ed.verify(ed.PublicKey(publicKey), message, signature);
  } on ArgumentError {
    return false;
  }
}
