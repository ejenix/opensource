// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart' show EnumValue;

/// CBOR tag (private-use range) identifying a serialized [EnumValue] constant.
const int _enumTag = 200;

/// Raised on malformed or unexpected CBOR input.
class CborException implements Exception {
  CborException(this.message);
  final String message;
  @override
  String toString() => 'CborException: $message';
}

/// A deterministic CBOR encoder covering exactly the types the bundle format
/// uses: integers, byte and text strings, arrays, booleans, null, and 64-bit
/// floats.
///
/// Encoding follows the core deterministic rules of RFC 8949 §4.2.1:
/// definite-length items and shortest-form integer arguments. Doubles are
/// always encoded as 64-bit floats, a deterministic choice. There is no reliance
/// on map-key ordering because the bundle schema is entirely positional
/// (arrays), which sidesteps the one genuinely subtle canonicalization rule.
class CborWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// The bytes written so far. The writer must not be used after this call.
  Uint8List takeBytes() => _out.takeBytes();

  /// Writes a signed integer (major type 0 or 1).
  void writeInt(int value) {
    if (value >= 0) {
      _writeTypeAndArg(0, value);
    } else {
      _writeTypeAndArg(1, -1 - value);
    }
  }

  /// Writes a byte string (major type 2).
  void writeBytes(List<int> bytes) {
    _writeTypeAndArg(2, bytes.length);
    _out.add(bytes);
  }

  /// Writes a UTF-8 text string (major type 3).
  void writeString(String value) {
    final encoded = utf8.encode(value);
    _writeTypeAndArg(3, encoded.length);
    _out.add(encoded);
  }

  /// Writes an array header of [length] items (major type 4). The caller writes
  /// the items next.
  void writeArrayHeader(int length) => _writeTypeAndArg(4, length);

  /// Writes a boolean (major type 7).
  void writeBool(bool value) => _out.addByte(value ? 0xF5 : 0xF4);

  /// Writes null (major type 7).
  void writeNull() => _out.addByte(0xF6);

  /// Writes a 64-bit float (major type 7, additional info 27).
  void writeDouble(double value) {
    _out.addByte((7 << 5) | 27);
    final bytes = ByteData(8)..setFloat64(0, value);
    _out.add(bytes.buffer.asUint8List());
  }

  /// Writes one of the constant-pool value kinds, preserving its type.
  void writeValue(Object? value) {
    switch (value) {
      case null:
        writeNull();
      case final bool b:
        writeBool(b);
      case final int i:
        writeInt(i);
      case final double d:
        writeDouble(d);
      case final String s:
        writeString(s);
      case final EnumValue e:
        // CBOR tag 200 (private use) wrapping [enumName, index, name].
        _writeTypeAndArg(6, _enumTag);
        writeArrayHeader(3);
        writeString(e.enumName);
        writeInt(e.index);
        writeString(e.name);
      default:
        throw CborException('unsupported value kind ${value.runtimeType}');
    }
  }

  void _writeTypeAndArg(int major, int arg) {
    final head = major << 5;
    if (arg < 24) {
      _out.addByte(head | arg);
    } else if (arg < 0x100) {
      _out
        ..addByte(head | 24)
        ..addByte(arg);
    } else if (arg < 0x10000) {
      _out.addByte(head | 25);
      _writeBig(arg, 2);
    } else if (arg < 0x100000000) {
      _out.addByte(head | 26);
      _writeBig(arg, 4);
    } else {
      _out.addByte(head | 27);
      _writeBig(arg, 8);
    }
  }

  void _writeBig(int arg, int byteCount) {
    for (var shift = (byteCount - 1) * 8; shift >= 0; shift -= 8) {
      _out.addByte((arg >> shift) & 0xFF);
    }
  }
}

/// A CBOR decoder matching [CborWriter]. It reads the same restricted type set
/// and rejects anything unexpected with a [CborException].
/// Bounds applied while decoding untrusted input.
///
/// Every field here exists because the value it caps is attacker-controlled:
/// the bytes arrive from a network before any signature has been checked, so
/// a length prefix must never be trusted enough to allocate against.
class DecodeLimits {
  const DecodeLimits({
    this.maxByteStringLength = 64 * 1024 * 1024,
    this.maxStringLength = 1024 * 1024,
    this.maxArrayLength = 1024 * 1024,
  });

  /// Largest byte string, covering a whole bundle body.
  final int maxByteStringLength;

  /// Largest text string — identifiers and version strings, not payloads.
  final int maxStringLength;

  /// Largest declared array count.
  final int maxArrayLength;
}

class CborReader {
  CborReader(this._bytes, {this.limits = const DecodeLimits()});

  /// Bounds applied while reading untrusted bytes.
  final DecodeLimits limits;

  final Uint8List _bytes;
  int _pos = 0;

  /// Whether all input has been consumed.
  bool get atEnd => _pos >= _bytes.length;

  /// Reads a signed integer.
  int readInt() {
    final (major, arg) = _readHead();
    return switch (major) {
      0 => arg,
      1 => -1 - arg,
      _ => throw CborException('expected integer, got major type $major'),
    };
  }

  /// Reads a byte string.
  Uint8List readBytes() {
    final (major, arg) = _readHead();
    if (major != 2) throw CborException('expected bytes, got major $major');
    _checkLength(arg, limits.maxByteStringLength, 'byte string');
    return _take(arg);
  }

  /// Reads a UTF-8 text string.
  String readString() {
    final (major, arg) = _readHead();
    if (major != 3) throw CborException('expected string, got major $major');
    _checkLength(arg, limits.maxStringLength, 'string');
    final raw = _take(arg);
    try {
      return utf8.decode(raw);
    } on FormatException catch (e) {
      // Callers catch CborException. Invalid UTF-8 used to escape as a
      // FormatException and bypass every typed handler above this.
      throw CborException('invalid UTF-8 in string: ${e.message}');
    }
  }

  /// Reads an array header, returning the item count.
  int readArrayHeader() {
    final (major, arg) = _readHead();
    if (major != 4) throw CborException('expected array, got major $major');
    // An unchecked count is an unchecked loop: a four-byte length can ask a
    // reader to iterate four billion times over a handful of bytes.
    _checkLength(arg, limits.maxArrayLength, 'array');
    return arg;
  }

  /// Fails before a declared length becomes an allocation or a loop bound.
  void _checkLength(int n, int max, String what) {
    if (n < 0 || n > max) {
      throw CborException('$what length $n exceeds limit $max');
    }
    if (n > _bytes.length - _pos && what != 'array') {
      throw CborException('$what length $n exceeds remaining input');
    }
  }

  /// Fails unless every byte has been consumed.
  ///
  /// Without this, anything appended after a complete document is silently
  /// ignored — including bytes outside the region a signature covers.
  void requireEndOfInput() {
    if (!atEnd) {
      throw CborException(
        '${_bytes.length - _pos} unexpected trailing byte(s)',
      );
    }
  }

  /// Reads a 64-bit float.
  double readDouble() {
    final head = _readByte();
    if (head != ((7 << 5) | 27)) {
      throw CborException(
        'expected float64 (0xFB), got 0x${head.toRadixString(16)}',
      );
    }
    final view = ByteData.sublistView(_take(8));
    return view.getFloat64(0);
  }

  /// Consumes a null item if the next value is null, returning whether it did.
  /// Used for optional slots in CBOR payloads.
  bool tryReadNull() {
    if (!atEnd && _bytes[_pos] == 0xF6) {
      _pos++;
      return true;
    }
    return false;
  }

  /// Reads a constant-pool value of any supported kind.
  Object? readValue() {
    final head = _bytes[_pos];
    final major = head >> 5;
    final ai = head & 0x1F;
    switch (major) {
      case 0:
      case 1:
        return readInt();
      case 3:
        return readString();
      case 6:
        final (_, tag) = _readHead();
        if (tag != _enumTag) {
          throw CborException('unexpected CBOR tag $tag');
        }
        if (readArrayHeader() != 3) {
          throw CborException('EnumValue must be a 3-element array');
        }
        return EnumValue(
          enumName: readString(),
          index: readInt(),
          name: readString(),
        );
      case 7:
        switch (ai) {
          case 20:
            _pos++;
            return false;
          case 21:
            _pos++;
            return true;
          case 22:
            _pos++;
            return null;
          case 27:
            return readDouble();
          default:
            throw CborException('unexpected simple value $ai');
        }
      default:
        throw CborException('unexpected major type $major for a value');
    }
  }

  (int, int) _readHead() {
    final ib = _readByte();
    final major = ib >> 5;
    final ai = ib & 0x1F;
    final int arg;
    if (ai < 24) {
      arg = ai;
    } else if (ai == 24) {
      arg = _readByte();
      // Canonical CBOR requires the shortest encoding of a value. Accepting a
      // longer one means two different byte strings decode identically, which
      // breaks the promise the whole format rests on: that a body hash
      // identifies exactly one encoding.
      if (arg < 24)
        throw CborException('non-canonical integer: $arg in 1 byte');
    } else if (ai == 25) {
      arg = _readN(2);
      if (arg < 256)
        throw CborException('non-canonical integer: $arg in 2 bytes');
    } else if (ai == 26) {
      arg = _readN(4);
      if (arg < 65536) {
        throw CborException('non-canonical integer: $arg in 4 bytes');
      }
    } else if (ai == 27) {
      arg = _readN(8);
    } else {
      throw CborException('reserved additional info $ai');
    }
    return (major, arg);
  }

  int _readN(int n) {
    var value = 0;
    for (var i = 0; i < n; i++) {
      value = (value << 8) | _readByte();
    }
    return value;
  }

  int _readByte() {
    if (_pos >= _bytes.length) {
      throw CborException('unexpected end of input');
    }
    return _bytes[_pos++];
  }

  Uint8List _take(int n) {
    if (_pos + n > _bytes.length) {
      throw CborException('unexpected end of input (needed $n bytes)');
    }
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return slice;
  }
}
