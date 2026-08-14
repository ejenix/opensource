// Copyright (c) Ejenix authors. MIT license.

/// The signed bundle format: canonical CBOR serialization of a compiled module,
/// wrapped with an Ed25519 signature over a content-hashing header.
///
/// [Bundle.sign] produces a bundle from a `Module`; [Bundle.encode] serializes
/// it; [Bundle.decode] parses it; [Bundle.verify] checks it against a
/// [TrustAnchors] set. The byte layout is normatively specified in
/// `spec/bundle.md`.
library;

export 'src/bundle.dart';
export 'src/cbor.dart' show CborException, CborReader, CborWriter;
export 'src/metadata.dart';
export 'src/module_codec.dart';
export 'src/signing.dart';
export 'src/uuid.dart';
