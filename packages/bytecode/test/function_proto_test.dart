// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

void main() {
  group('FunctionProto', () {
    test('exposes its fields', () {
      final fn = FunctionProto(
        name: 'f',
        paramCount: 2,
        registerCount: 4,
        code: Uint32List(0),
      );
      expect(fn.name, 'f');
      expect(fn.paramCount, 2);
      expect(fn.registerCount, 4);
      expect(fn.code, isEmpty);
    });

    test('asserts registerCount covers the parameters', () {
      expect(
        () => FunctionProto(
          name: 'f',
          paramCount: 3,
          registerCount: 1,
          code: Uint32List(0),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
