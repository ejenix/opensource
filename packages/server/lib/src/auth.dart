// Copyright (c) Ejenix authors. MIT license.

import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

/// Generates a fresh API key: 32 random bytes, hex-encoded.
String generateApiKey([Random? random]) {
  final rng = random ?? Random.secure();
  return [
    for (var i = 0; i < 32; i++) rng.nextInt(256),
  ].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The SHA-256 hex of an API key, as stored. The raw key is never persisted.
String hashApiKey(String key) => sha256
    .convert(key.codeUnits)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

/// Extracts a bearer token from the `Authorization` header, or `null`.
String? bearerToken(Request request) {
  final header = request.headers['authorization'];
  if (header == null) return null;
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return null;
  return header.substring(prefix.length).trim();
}

/// Constant-time string comparison to avoid leaking key-hash prefixes.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
