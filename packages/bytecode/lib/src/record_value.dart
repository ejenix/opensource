// Copyright (c) Ejenix authors. MIT license.

/// A runtime value of a Dart **record**, e.g. `(1, 'a')` or `(x: 1, y: 2)`.
///
/// Built by `record.new` and read by `record.get`. [positional] holds the
/// positional fields in order (accessed as `$1`, `$2`, …); [named] holds the
/// named fields keyed by name. Following Dart's record semantics, equality is
/// **structural** — two records are equal when they have the same shape and
/// field-by-field equal values — so records work as map keys and in `==`.
class InterpRecord {
  InterpRecord(this.positional, this.named);

  /// The positional fields, in source order. `$1` is `positional[0]`.
  final List<Object?> positional;

  /// The named fields, keyed by field name. Empty for a purely positional
  /// record.
  final Map<String, Object?> named;

  @override
  bool operator ==(Object other) {
    if (other is! InterpRecord) return false;
    if (positional.length != other.positional.length) return false;
    if (named.length != other.named.length) return false;
    for (var i = 0; i < positional.length; i++) {
      if (positional[i] != other.positional[i]) return false;
    }
    for (final entry in named.entries) {
      if (!other.named.containsKey(entry.key)) return false;
      if (other.named[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(positional),
    Object.hashAllUnordered(named.keys),
    Object.hashAll(named.values),
  );

  @override
  String toString() {
    final parts = [
      ...positional.map((v) => '$v'),
      ...named.entries.map((e) => '${e.key}: ${e.value}'),
    ];
    return '(${parts.join(', ')})';
  }
}
