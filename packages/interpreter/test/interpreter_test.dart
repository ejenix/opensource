// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// Builds a module from [functions] (entry = [entry]) and runs it with [args].
Object? runModule(
  List<FunctionProto> functions, {
  int entry = 0,
  List<Object?> args = const [],
  ConstantPool? constants,
  int maxCallDepth = 1024,
  int? stepLimit,
  OpProfile? profile,
}) {
  final module = Module(
    constants: constants ?? ConstantPool(),
    functions: functions,
    entryFunction: entry,
  );
  return Interpreter(
    module,
    maxCallDepth: maxCallDepth,
    stepLimit: stepLimit,
    profile: profile,
  ).run(args);
}

/// A single-function convenience wrapper.
Object? runFn(
  FunctionProto fn, {
  List<Object?> args = const [],
  ConstantPool? constants,
  int maxCallDepth = 1024,
  int? stepLimit,
  OpProfile? profile,
}) => runModule(
  [fn],
  args: args,
  constants: constants,
  maxCallDepth: maxCallDepth,
  stepLimit: stepLimit,
  profile: profile,
);

void main() {
  group('constants and moves', () {
    test('load.int / load.null / load.true / load.false', () {
      expect(
        runFn(
          (BytecodeBuilder()
                ..emitLoadInt(0, -7)
                ..emitA(Op.ret, 0))
              .toProto(name: 'i', paramCount: 0, registerCount: 1),
        ),
        -7,
      );
      expect(
        runFn(
          (BytecodeBuilder()
                ..emitA(Op.loadNull, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'n', paramCount: 0, registerCount: 1),
        ),
        isNull,
      );
      expect(
        runFn(
          (BytecodeBuilder()
                ..emitA(Op.loadTrue, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 't', paramCount: 0, registerCount: 1),
        ),
        isTrue,
      );
      expect(
        runFn(
          (BytecodeBuilder()
                ..emitA(Op.loadFalse, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'f', paramCount: 0, registerCount: 1),
        ),
        isFalse,
      );
    });

    test('load.const resolves a pooled string', () {
      final constants = ConstantPool();
      final k = constants.add('hello');
      final fn =
          (BytecodeBuilder()
                ..emitABx(Op.loadConst, 0, k)
                ..emitA(Op.ret, 0))
              .toProto(name: 's', paramCount: 0, registerCount: 1);
      expect(runFn(fn, constants: constants), 'hello');
    });

    test('move copies a register', () {
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 42)
                ..emitAB(Op.move, 1, 0)
                ..emitA(Op.ret, 1))
              .toProto(name: 'm', paramCount: 0, registerCount: 2);
      expect(runFn(fn), 42);
    });
  });

  group('integer arithmetic', () {
    Object? binOp(Op op, int x, int y) {
      final fn =
          (BytecodeBuilder()
                ..emitABC(op, 2, 0, 1)
                ..emitA(Op.ret, 2))
              .toProto(name: op.mnemonic, paramCount: 2, registerCount: 3);
      return runFn(fn, args: [x, y]);
    }

    test('add/sub/mul/div/mod', () {
      expect(binOp(Op.addInt, 3, 4), 7);
      expect(binOp(Op.subInt, 10, 3), 7);
      expect(binOp(Op.mulInt, 6, 7), 42);
      expect(binOp(Op.divInt, 17, 5), 3);
      expect(binOp(Op.modInt, 17, 5), 2);
      expect(binOp(Op.modInt, -7, 3), 2); // Dart % has divisor's sign
    });

    test('negate', () {
      final fn =
          (BytecodeBuilder()
                ..emitAB(Op.negInt, 1, 0)
                ..emitA(Op.ret, 1))
              .toProto(name: 'neg', paramCount: 1, registerCount: 2);
      expect(runFn(fn, args: [5]), -5);
    });
  });

  group('double arithmetic', () {
    Object? binOp(Op op, double x, double y) {
      final fn =
          (BytecodeBuilder()
                ..emitABC(op, 2, 0, 1)
                ..emitA(Op.ret, 2))
              .toProto(name: op.mnemonic, paramCount: 2, registerCount: 3);
      return runFn(fn, args: [x, y]);
    }

    test('add/sub/mul/div/mod and negate', () {
      expect(binOp(Op.addDouble, 1.5, 2.25), 3.75);
      expect(binOp(Op.subDouble, 5.0, 1.5), 3.5);
      expect(binOp(Op.mulDouble, 2.0, 2.5), 5.0);
      expect(binOp(Op.divDouble, 9.0, 2.0), 4.5);
      expect(binOp(Op.modDouble, 5.5, 2.0), 1.5);
      final neg =
          (BytecodeBuilder()
                ..emitAB(Op.negDouble, 1, 0)
                ..emitA(Op.ret, 1))
              .toProto(name: 'negd', paramCount: 1, registerCount: 2);
      expect(runFn(neg, args: [3.5]), -3.5);
    });

    test('i2d widens an int to a double', () {
      final fn =
          (BytecodeBuilder()
                ..emitAB(Op.i2d, 1, 0)
                ..emitA(Op.ret, 1))
              .toProto(name: 'i2d', paramCount: 1, registerCount: 2);
      final result = runFn(fn, args: [7]);
      expect(result, 7.0);
      expect(result, isA<double>());
    });
  });

  group('comparison and logic', () {
    Object? cmp(Op op, num x, num y) {
      final fn =
          (BytecodeBuilder()
                ..emitABC(op, 2, 0, 1)
                ..emitA(Op.ret, 2))
              .toProto(name: op.mnemonic, paramCount: 2, registerCount: 3);
      return runFn(fn, args: [x, y]);
    }

    test('integer comparisons', () {
      expect(cmp(Op.ltInt, 1, 2), isTrue);
      expect(cmp(Op.leInt, 2, 2), isTrue);
      expect(cmp(Op.gtInt, 3, 2), isTrue);
      expect(cmp(Op.geInt, 2, 3), isFalse);
      expect(cmp(Op.eqInt, 2, 2), isTrue);
      expect(cmp(Op.neInt, 2, 3), isTrue);
    });

    test('double comparisons', () {
      expect(cmp(Op.ltDouble, 1.0, 2.0), isTrue);
      expect(cmp(Op.leDouble, 2.0, 1.0), isFalse);
      expect(cmp(Op.gtDouble, 3.0, 2.0), isTrue);
      expect(cmp(Op.geDouble, 2.0, 2.0), isTrue);
    });

    test('structural eq/ne on strings', () {
      final constants = ConstantPool();
      final a = constants.add('x');
      final b = constants.add('y');
      final fn =
          (BytecodeBuilder()
                ..emitABx(Op.loadConst, 0, a)
                ..emitABx(Op.loadConst, 1, b)
                ..emitABC(Op.eq, 2, 0, 1)
                ..emitA(Op.ret, 2))
              .toProto(name: 'eq', paramCount: 0, registerCount: 3);
      expect(runFn(fn, constants: constants), isFalse);
    });

    test('logical not', () {
      final fn =
          (BytecodeBuilder()
                ..emitA(Op.loadFalse, 0)
                ..emitAB(Op.not, 1, 0)
                ..emitA(Op.ret, 1))
              .toProto(name: 'not', paramCount: 0, registerCount: 2);
      expect(runFn(fn), isTrue);
    });
  });

  group('control flow', () {
    test('branch selects the max of two ints', () {
      // max(a,b): if a >= b return a else return b
      final b = BytecodeBuilder();
      final elseL = b.newLabel();
      b
        ..emitABC(Op.geInt, 2, 0, 1)
        ..emitBranch(Op.jz, 2, elseL)
        ..emitA(Op.ret, 0)
        ..bind(elseL)
        ..emitA(Op.ret, 1);
      final fn = b.toProto(name: 'max', paramCount: 2, registerCount: 3);
      expect(runFn(fn, args: [9, 4]), 9);
      expect(runFn(fn, args: [3, 8]), 8);
    });

    test('loop computes a factorial', () {
      // while (n > 1) { acc *= n; n -= 1; } return acc
      final b = BytecodeBuilder();
      final loop = b.newLabel();
      final done = b.newLabel();
      b
        ..emitLoadInt(1, 1) // acc
        ..emitLoadInt(2, 1) // one
        ..bind(loop)
        ..emitABC(Op.gtInt, 3, 0, 2)
        ..emitBranch(Op.jz, 3, done)
        ..emitABC(Op.mulInt, 1, 1, 0)
        ..emitABC(Op.subInt, 0, 0, 2)
        ..emitJmp(loop)
        ..bind(done)
        ..emitA(Op.ret, 1);
      final fn = b.toProto(name: 'fact', paramCount: 1, registerCount: 4);
      expect(runFn(fn, args: [0]), 1);
      expect(runFn(fn, args: [5]), 120);
      expect(runFn(fn, args: [10]), 3628800);
    });
  });

  group('calls', () {
    FunctionProto buildFib() {
      final b = BytecodeBuilder();
      final elseL = b.newLabel();
      b
        ..emitLoadInt(1, 2)
        ..emitABC(Op.ltInt, 1, 0, 1) // n < 2
        ..emitBranch(Op.jz, 1, elseL)
        ..emitA(Op.ret, 0) // base case
        ..bind(elseL)
        ..emitABx(Op.loadFunc, 1, 0)
        ..emitLoadInt(2, 1)
        ..emitABC(Op.subInt, 2, 0, 2) // n-1 in R2
        ..emitABC(Op.call, 1, 0, 1) // fib(n-1) -> R1
        ..emitABx(Op.loadFunc, 3, 0)
        ..emitLoadInt(4, 2)
        ..emitABC(Op.subInt, 4, 0, 4) // n-2 in R4
        ..emitABC(Op.call, 3, 0, 1) // fib(n-2) -> R3
        ..emitABC(Op.addInt, 1, 1, 3)
        ..emitA(Op.ret, 1);
      return b.toProto(name: 'fib', paramCount: 1, registerCount: 5);
    }

    test('recursive fibonacci', () {
      final fib = buildFib();
      expect(runFn(fib, args: [0]), 0);
      expect(runFn(fib, args: [1]), 1);
      expect(runFn(fib, args: [10]), 55);
      expect(runFn(fib, args: [20]), 6765);
    });

    test('a callee returning void yields null', () {
      // main() { doNothing(); return 7; }
      final doNothing = (BytecodeBuilder()..emitNone(Op.retVoid)).toProto(
        name: 'doNothing',
        paramCount: 0,
        registerCount: 1,
      );
      final b = BytecodeBuilder()
        ..emitABx(Op.loadFunc, 0, 1) // F1 = doNothing
        ..emitABC(Op.call, 0, 0, 0) // R0 = doNothing()  (null)
        ..emitLoadInt(0, 7)
        ..emitA(Op.ret, 0);
      final main = b.toProto(name: 'main', paramCount: 0, registerCount: 1);
      expect(runModule([main, doNothing], entry: 0), 7);
    });
  });

  group('profiling', () {
    test('counts executed opcodes', () {
      final profile = OpProfile();
      final fn =
          (BytecodeBuilder()
                ..emitLoadInt(0, 1)
                ..emitLoadInt(1, 2)
                ..emitABC(Op.addInt, 0, 0, 1)
                ..emitA(Op.ret, 0))
              .toProto(name: 'p', paramCount: 0, registerCount: 2);
      runFn(fn, profile: profile);
      expect(profile.countOf(Op.loadInt), 2);
      expect(profile.countOf(Op.addInt), 1);
      expect(profile.countOf(Op.ret), 1);
      expect(profile.totalSteps, 4);
      expect(profile.hottest(1).single.key, Op.loadInt);
      profile.reset();
      expect(profile.totalSteps, 0);
    });
  });
}
