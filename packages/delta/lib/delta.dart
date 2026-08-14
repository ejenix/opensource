// Copyright (c) Ejenix authors. MIT license.

/// Delta bundles: a binary diff/patch engine over bundle bodies and the signed
/// delta-bundle envelope.
///
/// [BinaryDelta] computes and applies compressed byte patches. [DeltaBundle]
/// wraps a patch in the signed bundle envelope and verifies the post-patch hash
/// on apply. The format is specified in `spec/delta.md`.
library;

export 'src/binary_delta.dart';
export 'src/delta_bundle.dart';
