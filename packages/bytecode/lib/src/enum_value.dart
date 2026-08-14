// Copyright (c) Ejenix authors. MIT license.

/// A runtime value of a user-defined `enum`.
///
/// Enum values are interned into the constant pool (so `Color.red` is a
/// `load.const`) and serialized in the bundle body. Equality is by
/// (enum name, index) rather than identity, so the same value loaded from two
/// call sites compares equal — matching Dart's `==` on enums and making
/// `switch` on an enum work.
class EnumValue {
  const EnumValue({
    required this.enumName,
    required this.index,
    required this.name,
  });

  /// The declaring enum's name, e.g. `Color`.
  final String enumName;

  /// The zero-based declaration index of this value.
  final int index;

  /// This value's name, e.g. `red`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is EnumValue && other.enumName == enumName && other.index == index;

  @override
  int get hashCode => Object.hash(enumName, index);

  @override
  String toString() => '$enumName.$name';
}
