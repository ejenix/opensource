// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  test(
    'an async function returns a future that completes with its value',
    () async {
      // Future<int> f() async => 42;
      final f =
          (BytecodeBuilder()
                ..emitLoadInt(0, 42)
                ..emitA(Op.ret, 0))
              .toProto(
                name: 'f',
                paramCount: 0,
                registerCount: 1,
                isAsync: true,
              );
      final module = Module(constants: ConstantPool(), functions: [f]);
      final result = Interpreter(module).callFunctionAsync(f, const []);
      expect(result, isA<Future<Object?>>());
      expect(await result, 42);
    },
  );

  test('await suspends on a host-returned future and resumes', () async {
    // f() async { return await delayed(); }  where delayed() → Future(99).
    final f =
        (BytecodeBuilder()
              ..emitABx(Op.invokeStatic, 0, 0) // R0 = delayed()  (a Future)
              ..emitA(Op.awaitValue, 0) // R0 = await R0
              ..emitA(Op.ret, 0))
            .toProto(name: 'f', paramCount: 0, registerCount: 1, isAsync: true);
    final module = Module(
      constants: ConstantPool(),
      functions: [f],
      callSites: const [CallSite(selector: 'delayed', argCount: 0)],
    );
    final registry = HostRegistry.standard()
      ..registerGlobal(
        'delayed',
        (_, __) =>
            Future<Object?>.delayed(const Duration(milliseconds: 1), () => 99),
      );
    final value = await Interpreter(
      module,
      hostRegistry: registry,
    ).callFunctionAsync(f, const []);
    expect(value, 99);
  });

  test('an async function awaits another async function', () async {
    // inner() async => 7;  outer() async { return await inner() + 1; }
    final inner =
        (BytecodeBuilder()
              ..emitLoadInt(0, 7)
              ..emitA(Op.ret, 0))
            .toProto(
              name: 'inner',
              paramCount: 0,
              registerCount: 1,
              isAsync: true,
            );
    final outer =
        (BytecodeBuilder()
              ..emitABx(Op.loadFunc, 0, 0) // R0 = inner
              ..emitABC(Op.call, 0, 0, 0) // R0 = inner()  (a Future)
              ..emitA(Op.awaitValue, 0) // R0 = await R0  → 7
              ..emitLoadInt(1, 1)
              ..emitABC(Op.addInt, 0, 0, 1) // R0 = 7 + 1
              ..emitA(Op.ret, 0))
            .toProto(
              name: 'outer',
              paramCount: 0,
              registerCount: 2,
              isAsync: true,
            );
    final module = Module(
      constants: ConstantPool(),
      functions: [inner, outer],
      entryFunction: 1,
    );
    expect(await Interpreter(module).runAsync(), 8);
  });

  test('await of a non-future yields the value unchanged', () async {
    // f() async { return await 5; }
    final f =
        (BytecodeBuilder()
              ..emitLoadInt(0, 5)
              ..emitA(Op.awaitValue, 0)
              ..emitA(Op.ret, 0))
            .toProto(name: 'f', paramCount: 0, registerCount: 1, isAsync: true);
    final module = Module(constants: ConstantPool(), functions: [f]);
    expect(await Interpreter(module).callFunctionAsync(f, const []), 5);
  });

  test('calling an async function synchronously is a typed error', () {
    final f =
        (BytecodeBuilder()
              ..emitLoadInt(0, 1)
              ..emitA(Op.ret, 0))
            .toProto(name: 'f', paramCount: 0, registerCount: 1, isAsync: true);
    final module = Module(constants: ConstantPool(), functions: [f]);
    expect(
      () => Interpreter(module).callFunction(f, const []),
      throwsA(isA<InterpreterException>()),
    );
  });

  test(
    'a sync function still runs synchronously through callFunctionAsync',
    () async {
      final f =
          (BytecodeBuilder()
                ..emitLoadInt(0, 3)
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 1);
      final module = Module(constants: ConstantPool(), functions: [f]);
      expect(await Interpreter(module).callFunctionAsync(f, const []), 3);
    },
  );
}
