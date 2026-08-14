// Copyright (c) Ejenix authors. MIT license.

import 'dart:math';
import 'dart:typed_data';

/// Generates a UUIDv7 (RFC 9562 §5.7): a 48-bit big-endian Unix-millisecond
/// timestamp followed by 74 random bits, with the version and variant fields
/// set. Version 7 is time-ordered, so bundle ids sort by creation time — useful
/// for the control plane's history views.
///
/// [millis] and [random] are injectable for deterministic tests.
Uint8List uuidV7({int? millis, Random? random}) {
  final ms = millis ?? DateTime.now().millisecondsSinceEpoch;
  final rng = random ?? Random.secure();
  final bytes = Uint8List(16);

  // 48-bit timestamp, big-endian, in the first six bytes.
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xFF;
  }
  // Remaining bytes are random.
  for (var i = 6; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  // Version 7 in the high nibble of byte 6.
  bytes[6] = (bytes[6] & 0x0F) | 0x70;
  // Variant 0b10 in the high bits of byte 8.
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  return bytes;
}

/// Formats a 16-byte UUID as the canonical 8-4-4-4-12 hex string.
String formatUuid(Uint8List uuid) {
  if (uuid.length != 16) {
    throw ArgumentError.value(uuid.length, 'uuid.length', 'must be 16');
  }
  final hex = [
    for (final b in uuid) b.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
