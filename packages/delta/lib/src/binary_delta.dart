// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Raised on a malformed or inapplicable patch.
class DeltaException implements Exception {
  DeltaException(this.message);
  final String message;
  @override
  String toString() => 'DeltaException: $message';
}

/// A binary diff/patch engine over byte buffers (brief §6.5).
///
/// The patch is a `COPY`/`ADD` op stream — copy a run from the base at an
/// offset, or add literal bytes — in the lineage of VCDIFF (RFC 3284) and
/// bsdiff (Percival, 2003). Matches are found with a hash index over the base's
/// 4-byte windows and a greedy longest-extension search, and the whole op
/// stream is zlib-compressed. For localized edits — the common patch case —
/// most of the target is expressed as `COPY`s of the base, so the patch is a
/// small fraction of a full bundle.
class BinaryDelta {
  static const int _minMatch = 4;
  static const int _maxCandidatesPerKey = 64;

  /// Computes a compressed patch that transforms [base] into [target].
  static Uint8List computeDelta(Uint8List base, Uint8List target) {
    final raw = <int>[];
    _writeVarint(raw, target.length);

    final index = _buildIndex(base);
    final pending = <int>[];

    void flushAdd() {
      if (pending.isEmpty) return;
      raw.add(_opAdd);
      _writeVarint(raw, pending.length);
      raw.addAll(pending);
      pending.clear();
    }

    var p = 0;
    while (p < target.length) {
      final match = _bestMatch(base, target, p, index);
      if (match != null && match.length >= _minMatch) {
        flushAdd();
        raw.add(_opCopy);
        _writeVarint(raw, match.offset);
        _writeVarint(raw, match.length);
        p += match.length;
      } else {
        pending.add(target[p]);
        p++;
      }
    }
    flushAdd();

    return ZLibEncoder().encodeBytes(raw);
  }

  /// Applies [patch] to [base], returning the reconstructed target.
  ///
  /// Throws [DeltaException] if the patch is malformed or references data
  /// outside the base.
  static Uint8List applyDelta(Uint8List base, Uint8List patch) {
    final Uint8List raw;
    try {
      raw = ZLibDecoder().decodeBytes(patch);
    } on Object {
      throw DeltaException('patch is not valid zlib data');
    }

    var pos = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (pos >= raw.length) throw DeltaException('truncated varint');
        final byte = raw[pos++];
        result |= (byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
      }
    }

    final targetLength = readVarint();
    final out = Uint8List(targetLength);
    var o = 0;

    while (pos < raw.length) {
      final op = raw[pos++];
      switch (op) {
        case _opCopy:
          final offset = readVarint();
          final length = readVarint();
          if (offset < 0 ||
              offset + length > base.length ||
              o + length > targetLength) {
            throw DeltaException('COPY out of range');
          }
          out.setRange(o, o + length, base, offset);
          o += length;
        case _opAdd:
          final length = readVarint();
          if (pos + length > raw.length || o + length > targetLength) {
            throw DeltaException('ADD out of range');
          }
          out.setRange(o, o + length, raw, pos);
          pos += length;
          o += length;
        default:
          throw DeltaException('unknown op $op');
      }
    }
    if (o != targetLength) {
      throw DeltaException('patch produced $o bytes, expected $targetLength');
    }
    return out;
  }

  static const int _opCopy = 0;
  static const int _opAdd = 1;

  static Map<int, List<int>> _buildIndex(Uint8List base) {
    final index = <int, List<int>>{};
    for (var i = 0; i + _minMatch <= base.length; i++) {
      final key = _window(base, i);
      final list = index[key] ??= <int>[];
      list.add(i);
      if (list.length > _maxCandidatesPerKey) list.removeAt(0);
    }
    return index;
  }

  static _Match? _bestMatch(
    Uint8List base,
    Uint8List target,
    int p,
    Map<int, List<int>> index,
  ) {
    if (p + _minMatch > target.length) return null;
    final candidates = index[_window(target, p)];
    if (candidates == null) return null;
    var bestLength = 0;
    var bestOffset = 0;
    for (final c in candidates) {
      final maxLength = base.length - c < target.length - p
          ? base.length - c
          : target.length - p;
      var length = 0;
      while (length < maxLength && base[c + length] == target[p + length]) {
        length++;
      }
      if (length > bestLength) {
        bestLength = length;
        bestOffset = c;
      }
    }
    return bestLength == 0 ? null : _Match(bestOffset, bestLength);
  }

  static int _window(Uint8List bytes, int i) =>
      bytes[i] |
      (bytes[i + 1] << 8) |
      (bytes[i + 2] << 16) |
      (bytes[i + 3] << 24);

  static void _writeVarint(List<int> out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
  }
}

class _Match {
  _Match(this.offset, this.length);
  final int offset;
  final int length;
}
