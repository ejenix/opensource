// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('ConstantPool', () {
    late ConstantPool pool;
    setUp(() => pool = ConstantPool());

    test('interns equal strings to one slot', () {
      final a = pool.add('hello');
      final b = pool.add('hel${'lo'}'); // distinct instance, equal value
      expect(a, b);
      expect(pool.length, 1);
    });

    test('deduplicates equal ints and doubles independently', () {
      final i = pool.add(1);
      final d = pool.add(1.0);
      expect(
        i,
        isNot(d),
        reason: 'int 1 and double 1.0 are distinct constants',
      );
      expect(pool.add(1), i);
      expect(pool.add(1.0), d);
      expect(pool.length, 2);
    });

    test('keeps -0.0 and 0.0 in distinct slots', () {
      final zero = pool.add(0.0);
      final negZero = pool.add(-0.0);
      expect(zero, isNot(negZero));
      expect(pool[zero], 0.0);
      expect((pool[negZero] as double).isNegative, isTrue);
    });

    test('deduplicates NaNs that share a bit pattern', () {
      final a = pool.add(double.nan);
      final b = pool.add(double.nan);
      expect(a, b);
      expect(pool.length, 1);
    });

    test('stores null, true, and false as fixed singletons', () {
      expect(pool.add(null), pool.add(null));
      expect(pool.add(true), pool.add(true));
      expect(pool.add(false), pool.add(false));
      expect(pool.add(true), isNot(pool.add(false)));
      expect(pool.length, 3);
    });

    test('does not confuse true with the integer 1', () {
      final one = pool.add(1);
      final t = pool.add(true);
      expect(one, isNot(t));
    });

    test('preserves insertion order and values', () {
      pool.add('a');
      pool.add(42);
      pool.add(3.14);
      expect(pool.values, ['a', 42, 3.14]);
    });

    test('rejects unsupported constant kinds', () {
      expect(() => pool.add(DateTime(2026)), throwsArgumentError);
    });
  });
}
