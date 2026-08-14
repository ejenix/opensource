// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  group('sync* generators (hand-built bytecode)', () {
    FunctionProto yields123() =>
        (BytecodeBuilder()
              ..emitLoadInt(0, 1)
              ..emitA(Op.yieldValue, 0)
              ..emitLoadInt(0, 2)
              ..emitA(Op.yieldValue, 0)
              ..emitLoadInt(0, 3)
              ..emitA(Op.yieldValue, 0)
              ..emitNone(Op.retVoid))
            .toProto(
              name: 'g',
              paramCount: 0,
              registerCount: 1,
              isSyncStar: true,
            );

    test('calling a generator returns a lazy Iterable', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [yields123()],
        entryFunction: 0,
      );
      final result = Interpreter(module).run();
      expect(result, isA<Iterable<Object?>>());
      expect((result! as Iterable).toList(), [1, 2, 3]);
    });

    test('the generator can be iterated more than once', () {
      final module = Module(
        constants: ConstantPool(),
        functions: [yields123()],
        entryFunction: 0,
      );
      final it = Interpreter(module).run()! as Iterable;
      expect(it.length, 3);
      expect(it.length, 3); // fresh activation each time
    });

    test('an infinite generator is consumed lazily', () {
      // R0 = 0; R1 = 1; loop: yield R0; R0 += R1; jmp loop
      final b = BytecodeBuilder();
      final loop = b.newLabel();
      b
        ..emitLoadInt(0, 0)
        ..emitLoadInt(1, 1)
        ..bind(loop)
        ..emitA(Op.yieldValue, 0)
        ..emitABC(Op.addInt, 0, 0, 1)
        ..emitJmp(loop);
      final gen = b.toProto(
        name: 'nats',
        paramCount: 0,
        registerCount: 2,
        isSyncStar: true,
      );
      final module = Module(
        constants: ConstantPool(),
        functions: [gen],
        entryFunction: 0,
      );
      final nats = Interpreter(module).run()! as Iterable;
      expect(nats.take(5).toList(), [0, 1, 2, 3, 4]);
    });

    test('async* returns a Stream', () async {
      final gen =
          (BytecodeBuilder()
                ..emitLoadInt(0, 7)
                ..emitA(Op.yieldValue, 0)
                ..emitNone(Op.retVoid))
              .toProto(
                name: 'g',
                paramCount: 0,
                registerCount: 1,
                isAsyncStar: true,
              );
      final module = Module(
        constants: ConstantPool(),
        functions: [gen],
        entryFunction: 0,
      );
      final result = Interpreter(module).run();
      expect(result, isA<Stream<Object?>>());
      expect(await (result! as Stream).toList(), [7]);
    });
  });

  group('static fields (module globals)', () {
    test('the static initializer populates a global read by main', () {
      // main (0): load.global R0, 0; ret R0
      final main =
          (BytecodeBuilder()
                ..emitABx(Op.loadGlobal, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 1);
      // clinit (1): load.int R0, 42; store.global R0, 0; ret.void
      final clinit =
          (BytecodeBuilder()
                ..emitLoadInt(0, 42)
                ..emitABx(Op.storeGlobal, 0, 0)
                ..emitNone(Op.retVoid))
              .toProto(name: '<clinit>', paramCount: 0, registerCount: 1);
      final module = Module(
        constants: ConstantPool(),
        functions: [main, clinit],
        entryFunction: 0,
        globalCount: 1,
        staticInit: 1,
      );
      expect(Interpreter(module).run(), 42);
    });
  });

  group('generic Iterable host methods', () {
    final r = HostRegistry.standard();
    Object? call(Object? recv, String selector, [List<Object?> a = const []]) =>
        r.resolve(recv, selector)!(recv, a);

    test('take / skip / toList on a lazy iterable', () {
      final lazy = [1, 2, 3, 4, 5].where((x) => true); // a non-List Iterable
      expect(call(lazy, 'take', [2]), [1, 2]);
      expect(call(lazy, 'skip', [3]), [4, 5]);
      expect(call(lazy, 'length'), 5);
      expect(call(lazy, 'first'), 1);
      expect(call(lazy, 'contains', [3]), isTrue);
    });
  });

  group('invoke.dyn falls back to Object members', () {
    test('== on an instance with no override is identity', () {
      // class C {} ; main builds two instances and compares each pair.
      final b = BytecodeBuilder();
      b
        ..emitABx(Op.alloc, 0, 0) // R0 = C()
        ..emitAB(Op.move, 1, 0) // R1 = receiver (R0)
        ..emitAB(Op.move, 2, 0) // R2 = argument (the same instance)
        ..emitABx(Op.invokeDyn, 1, 0) // R1 = R1 == R2  (site 0: '==', 1 arg)
        ..emitA(Op.ret, 1);
      final main = b.toProto(name: 'main', paramCount: 0, registerCount: 3);
      final module = Module(
        constants: ConstantPool(),
        functions: [main],
        entryFunction: 0,
        callSites: const [CallSite(selector: '==', argCount: 1)],
        classes: const [
          ClassDescriptor(
            name: 'C',
            fieldCount: 0,
            superIndex: -1,
            methods: {},
          ),
        ],
      );
      expect(Interpreter(module).run(), isTrue);
    });
  });
}
