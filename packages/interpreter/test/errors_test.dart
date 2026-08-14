// Copyright (c) Ejenix authors. MIT license.

import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Interpreter interpreterFor(
  List<FunctionProto> functions, {
  int entry = 0,
  ConstantPool? constants,
  int maxCallDepth = 1024,
  int? stepLimit,
}) => Interpreter(
  Module(
    constants: constants ?? ConstantPool(),
    functions: functions,
    entryFunction: entry,
  ),
  maxCallDepth: maxCallDepth,
  stepLimit: stepLimit,
);

void main() {
  group('arithmetic faults', () {
    test('integer division by zero', () {
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 1)
                ..emitLoadInt(1, 0)
                ..emitABC(Op.divInt, 0, 0, 1)
                ..emitA(Op.ret, 0))
              .toProto(name: 'div0', paramCount: 0, registerCount: 2);
      expect(
        () => interpreterFor([fn]).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('division by zero'),
          ),
        ),
      );
    });

    test('integer modulo by zero', () {
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 1)
                ..emitLoadInt(1, 0)
                ..emitABC(Op.modInt, 0, 0, 1)
                ..emitA(Op.ret, 0))
              .toProto(name: 'mod0', paramCount: 0, registerCount: 2);
      expect(
        () => interpreterFor([fn]).run(),
        throwsA(isA<InterpreterException>()),
      );
    });
  });

  group('call faults', () {
    test('calling a non-callable value', () {
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 5)
                ..emitABC(Op.call, 0, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'bad', paramCount: 0, registerCount: 1);
      expect(
        () => interpreterFor([fn]).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('not callable'),
          ),
        ),
      );
    });

    test('arity mismatch at a call site', () {
      // callee expects 1 arg; call passes 0.
      final callee = (BytecodeBuilder()..emitA(Op.ret, 0)).toProto(
        name: 'callee',
        paramCount: 1,
        registerCount: 1,
      );
      final main =
          (BytecodeBuilder()
                ..emitABx(Op.loadFunc, 0, 1)
                ..emitABC(Op.call, 0, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 1);
      expect(
        () => interpreterFor([main, callee]).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('arity mismatch'),
          ),
        ),
      );
    });

    test('arity mismatch at the entry point', () {
      final fn = (BytecodeBuilder()..emitA(Op.ret, 0)).toProto(
        name: 'needsOne',
        paramCount: 1,
        registerCount: 1,
      );
      expect(
        () => interpreterFor([fn]).run(),
        throwsA(isA<InterpreterException>()),
      );
    });

    test('call stack overflow is a bounded fault, not a native crash', () {
      // loop() calls loop() forever.
      final loop =
          (BytecodeBuilder()
                ..emitABx(Op.loadFunc, 0, 0)
                ..emitABC(Op.call, 0, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'loop', paramCount: 0, registerCount: 1);
      expect(
        () => interpreterFor([loop], maxCallDepth: 16).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('stack overflow'),
          ),
        ),
      );
    });
  });

  group('sandbox limits', () {
    test('step limit bounds an infinite loop', () {
      final b = BytecodeBuilder();
      final loop = b.newLabel();
      b
        ..bind(loop)
        ..emitJmp(loop);
      final fn = b.toProto(name: 'spin', paramCount: 0, registerCount: 1);
      expect(
        () => interpreterFor([fn], stepLimit: 1000).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('step limit'),
          ),
        ),
      );
    });
  });

  group('malformed modules', () {
    test('module without an entry function', () {
      final fn = (BytecodeBuilder()..emitNone(Op.retVoid)).toProto(
        name: 'lib',
        paramCount: 0,
        registerCount: 1,
      );
      final module = Module(constants: ConstantPool(), functions: [fn]);
      expect(
        () => Interpreter(module).run(),
        throwsA(isA<InterpreterException>()),
      );
    });

    test('a dangling pfx prefix is rejected', () {
      final code = Uint32List.fromList([
        Instruction.of(Op.pfx).word,
        Instruction.of(Op.pfx).word,
      ]);
      final fn = FunctionProto(
        name: 'bad',
        paramCount: 0,
        registerCount: 1,
        code: code,
      );
      expect(
        () => interpreterFor([fn]).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('dangling pfx'),
          ),
        ),
      );
    });
  });

  group('error formatting', () {
    test('includes the fault site in toString', () {
      final e = InterpreterException('boom', pc: 3, functionName: 'f');
      expect(e.toString(), 'InterpreterException: boom at f+3');
    });

    test('uncaught wraps the thrown value', () {
      final e = InterpreterUncaughtException('oops', pc: 1, functionName: 'g');
      expect(e.thrown, 'oops');
      expect(e.toString(), contains('uncaught exception: oops'));
    });
  });
}
