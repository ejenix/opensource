// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'enum_value.dart';

/// A per-module, indexed table of literal constants (brief §6.1).
///
/// Adding an equal value twice returns the same index: strings are interned and
/// numbers are deduplicated, so identical literals across a module share one
/// slot. Deduplication is type-aware — `1` (int) and `1.0` (double) are equal
/// under Dart `==` but occupy distinct slots here, because the interpreter must
/// recover the original runtime type.
///
/// Only literal constant kinds are stored: `Null`, `bool`, `int`, `double`, and
/// `String`. Higher-level descriptors (types, functions) live in their own
/// tables, not here.
class ConstantPool {
  final List<Object?> _values = [];

  // Type-segregated dedup indices avoid the `1 == 1.0` collision and give O(1)
  // interning. `bool` and `Null` are handled by fixed slots, not a map.
  final Map<int, int> _ints = {};
  // Doubles are keyed by their exact 64-bit pattern (as two 32-bit halves), not
  // by value: this keeps `-0.0` and `0.0` in distinct slots and deduplicates
  // NaNs that share a bit pattern, neither of which value equality can do.
  final Map<(int, int), int> _doubles = {};
  final Map<String, int> _strings = {};
  final Map<EnumValue, int> _enums = {};
  int _nullSlot = -1;
  int _trueSlot = -1;
  int _falseSlot = -1;

  /// The number of constants in the pool.
  int get length => _values.length;

  /// An unmodifiable, ordered view of the pooled constants.
  List<Object?> get values => List.unmodifiable(_values);

  /// Returns the constant at [index].
  Object? operator [](int index) => _values[index];

  /// Interns [value] and returns its pool index.
  ///
  /// Equal values of the same kind return the same index. Supported kinds are
  /// `Null`, `bool`, `int`, `double`, and `String`; anything else throws
  /// [ArgumentError].
  int add(Object? value) {
    switch (value) {
      case null:
        return _nullSlot >= 0 ? _nullSlot : (_nullSlot = _append(null));
      case true:
        return _trueSlot >= 0 ? _trueSlot : (_trueSlot = _append(true));
      case false:
        return _falseSlot >= 0 ? _falseSlot : (_falseSlot = _append(false));
      case final int i:
        return _ints[i] ??= _append(i);
      case final double d:
        return _doubles[_doubleKey(d)] ??= _append(d);
      case final String s:
        return _strings[s] ??= _append(s);
      case final EnumValue e:
        return _enums[e] ??= _append(e);
      default:
        throw ArgumentError.value(
          value,
          'value',
          'unsupported constant kind ${value.runtimeType}',
        );
    }
  }

  int _append(Object? value) {
    final index = _values.length;
    _values.add(value);
    return index;
  }

  static (int, int) _doubleKey(double d) {
    final bytes = ByteData(8)..setFloat64(0, d);
    return (bytes.getUint32(0), bytes.getUint32(4));
  }
}
