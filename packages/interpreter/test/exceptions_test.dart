// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  group('throw / catch (hand-built bytecode)', () {
    test('a throw is caught by a handler in the same frame', () {
      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..bind(start)
        ..emitLoadInt(0, 5)
        ..emitA(Op.throwValue, 0)
        ..bind(end)
        ..emitLoadInt(1, 99) // normal fall-through (never reached)
        ..emitA(Op.ret, 1)
        ..bind(target)
        ..emitA(Op.ret, 1) // R1 holds the caught value
        ..addHandler(start, end, target, 1);
      final fn = b.toProto(name: 'f', paramCount: 0, registerCount: 2);
      final module = Module(
        constants: ConstantPool(),
        functions: [fn],
        entryFunction: 0,
      );
      expect(Interpreter(module).run(), 5);
    });

    test('an uncaught throw escapes as InterpreterUncaughtException', () {
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 7)
                ..emitA(Op.throwValue, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 1);
      final module = Module(
        constants: ConstantPool(),
        functions: [fn],
        entryFunction: 0,
      );
      expect(
        () => Interpreter(module).run(),
        throwsA(
          isA<InterpreterUncaughtException>().having(
            (e) => e.thrown,
            'thrown',
            7,
          ),
        ),
      );
    });

    test('a throw unwinds from a callee to a handler in the caller', () {
      // callee (index 0): throws 42, no handler of its own.
      final callee =
          (BytecodeBuilder()
                ..emitLoadInt(0, 42)
                ..emitA(Op.throwValue, 0))
              .toProto(name: 'callee', paramCount: 0, registerCount: 1);

      // main (index 1): calls callee inside a protected region.
      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..bind(start)
        ..emitABx(Op.loadFunc, 0, 0) // R0 = callee
        ..emitABC(Op.call, 0, 0, 0) // R0 = callee()
        ..bind(end)
        ..emitA(Op.ret, 0) // normal path (never reached)
        ..bind(target)
        ..emitA(Op.ret, 1) // R1 holds the caught value
        ..addHandler(start, end, target, 1);
      final mainFn = b.toProto(name: 'main', paramCount: 0, registerCount: 2);

      final module = Module(
        constants: ConstantPool(),
        functions: [callee, mainFn],
        entryFunction: 1,
      );
      expect(Interpreter(module).run(), 42);
    });

    test('a VM fault inside a protected region is not caught', () {
      // A failing `as` cast raises an InterpreterException (a VM fault), which
      // must propagate past the guest handler rather than be caught.
      final k = ConstantPool();
      final str = k.add('x');
      final intSpec = k.add('int');
      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..bind(start)
        ..emitABx(Op.loadConst, 0, str)
        ..emitABx(Op.asType, 0, intSpec) // 'x' as int -> fault
        ..bind(end)
        ..emitA(Op.ret, 0)
        ..bind(target)
        ..emitLoadInt(1, -1)
        ..emitA(Op.ret, 1)
        ..addHandler(start, end, target, 1);
      final fn = b.toProto(name: 'f', paramCount: 0, registerCount: 2);
      final module = Module(constants: k, functions: [fn], entryFunction: 0);
      expect(
        () => Interpreter(module).run(),
        throwsA(
          allOf(
            isA<InterpreterException>(),
            isNot(isA<InterpreterUncaughtException>()),
          ),
        ),
      );
    });

    test('a Dart error from a host global is catchable', () {
      // A host global that throws a real Dart exception: the handler catches it
      // and the frame returns the caught object.
      final registry = HostRegistry.standard()
        ..registerGlobal('boom', (_, _) => throw const FormatException('nope'));

      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..bind(start)
        ..emitABx(Op.invokeStatic, 0, 0) // boom()
        ..bind(end)
        ..emitA(Op.ret, 0)
        ..bind(target)
        ..emitA(Op.ret, 1)
        ..addHandler(start, end, target, 1);
      final fn = b.toProto(name: 'f', paramCount: 0, registerCount: 2);
      final module = Module(
        constants: ConstantPool(),
        functions: [fn],
        entryFunction: 0,
        callSites: const [CallSite(selector: 'boom', argCount: 0)],
      );
      final result = Interpreter(module, hostRegistry: registry).run();
      expect(result, isA<FormatException>());
    });
  });

  group('host exception/error constructors', () {
    final r = HostRegistry.standard();

    Object? call(String name, [Object? message]) =>
        r.resolveGlobal(name)!(null, [
          if (message != null) {'message': message} else const {},
        ]);

    test('build real Dart objects from a {message} map', () {
      expect(call('Exception', 'e'), isA<Exception>());
      expect(call('FormatException', 'e'), isA<FormatException>());
      expect(call('StateError', 'e'), isA<StateError>());
      expect(call('ArgumentError', 'e'), isA<ArgumentError>());
      expect(call('RangeError', 'e'), isA<RangeError>());
      expect(call('UnsupportedError', 'e'), isA<UnsupportedError>());
      expect(call('UnimplementedError', 'e'), isA<UnimplementedError>());
    });

    test('default to an empty message when none is given', () {
      expect(call('FormatException'), isA<FormatException>());
      expect(call('StateError'), isA<StateError>());
      expect(call('UnsupportedError'), isA<UnsupportedError>());
    });
  });

  group('numeric-parse host globals', () {
    final r = HostRegistry.standard();
    Object? parse(String name, String source) => r.resolveGlobal(name)!(null, [
      {'source': source},
    ]);

    test('int.parse / int.tryParse', () {
      expect(parse('int.parse', '10'), 10);
      expect(parse('int.tryParse', 'nope'), isNull);
    });

    test('double.parse / double.tryParse', () {
      expect(parse('double.parse', '1.5'), 1.5);
      expect(parse('double.tryParse', 'nope'), isNull);
    });
  });
}
