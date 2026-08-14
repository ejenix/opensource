// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('InterpRecord', () {
    test('exposes positional and named fields', () {
      final r = InterpRecord([1, 2], {'name': 'x'});
      expect(r.positional, [1, 2]);
      expect(r.named, {'name': 'x'});
    });

    test('structural equality over positional fields', () {
      expect(InterpRecord([1, 2], const {}), InterpRecord([1, 2], const {}));
      expect(
        InterpRecord([1, 2], const {}),
        isNot(InterpRecord([1, 3], const {})),
      );
      expect(
        InterpRecord([1, 2], const {}),
        isNot(InterpRecord([1], const {})),
      );
    });

    test('structural equality over named fields', () {
      expect(
        InterpRecord(const [], {'x': 1, 'y': 2}),
        InterpRecord(const [], {'y': 2, 'x': 1}), // order-independent
      );
      expect(
        InterpRecord(const [], {'x': 1}),
        isNot(InterpRecord(const [], {'x': 2})),
      );
      expect(
        InterpRecord(const [], {'x': 1}),
        isNot(InterpRecord(const [], {'z': 1})),
      );
      expect(
        InterpRecord(const [], {'x': 1}),
        isNot(InterpRecord(const [], {'x': 1, 'y': 2})),
      );
    });

    test('a non-record is never equal', () {
      expect(InterpRecord([1], const {}) == 'not a record', isFalse);
    });

    test('equal records share a hashCode', () {
      final a = InterpRecord([1, 2], {'k': 3});
      final b = InterpRecord([1, 2], {'k': 3});
      expect(a.hashCode, b.hashCode);
    });

    test('toString renders positional then named fields', () {
      expect(InterpRecord([1, 2], const {}).toString(), '(1, 2)');
      expect(InterpRecord([1], {'k': 2}).toString(), '(1, k: 2)');
      expect(InterpRecord(const [], {'x': 5}).toString(), '(x: 5)');
    });
  });
}
