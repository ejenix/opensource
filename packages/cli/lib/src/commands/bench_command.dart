// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';

import '../base_command.dart';

/// `ejenix bench` — run the built-in interpreter benchmark suite.
///
/// Reports bytecode-op throughput on the current machine. It is a coarse,
/// reproducible micro-benchmark (recursive Fibonacci, an integer loop) that
/// feeds `docs/benchmarks.md`; every result names the machine and Dart version
/// so the number is falsifiable (brief §12).
class BenchCommand extends EjenixCommand {
  BenchCommand() {
    argParser.addOption(
      'iterations',
      help: 'Repetitions per benchmark.',
      defaultsTo: '5',
    );
  }

  @override
  String get name => 'bench';

  @override
  String get description => 'Run the built-in interpreter benchmark suite.';

  @override
  Future<int> execute() async {
    final iterations = int.tryParse(argResults!['iterations'] as String) ?? 5;

    final results = <Map<String, Object>>[
      _run('fib(30)', _fibModule(), const [30], iterations),
      _run('sum-loop(1e6)', _loopModule(), const [1000000], iterations),
      _run('dispatch(1e6)', _dispatchModule(), const [1000000], iterations),
    ];

    for (final r in results) {
      console.info(
        '${(r['name'] as String).padRight(16)} '
        '${(r['nsPerOp'] as double).toStringAsFixed(1)} ns/op   '
        '${_fmt(r['opsPerSec'] as double)} ops/sec',
      );
    }
    console.emitJson({'benchmarks': results});
    return 0;
  }

  Map<String, Object> _run(
    String name,
    Module module,
    List<Object?> args,
    int iterations,
  ) {
    // Warm up.
    Interpreter(module).run(args);

    var bestNsPerOp = double.infinity;
    var steps = 0;
    for (var i = 0; i < iterations; i++) {
      final profile = OpProfile();
      final sw = Stopwatch()..start();
      Interpreter(module, profile: profile).run(args);
      sw.stop();
      steps = profile.totalSteps;
      final nsPerOp = sw.elapsedMicroseconds * 1000 / steps;
      if (nsPerOp < bestNsPerOp) bestNsPerOp = nsPerOp;
    }
    return {
      'name': name,
      'steps': steps,
      'nsPerOp': bestNsPerOp,
      'opsPerSec': 1e9 / bestNsPerOp,
    };
  }

  static String _fmt(double n) {
    if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)}G';
    if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(2)}M';
    if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(2)}K';
    return n.toStringAsFixed(0);
  }

  // fib(n) = n < 2 ? n : fib(n-1) + fib(n-2)
  static Module _fibModule() {
    final b = BytecodeBuilder();
    final elseL = b.newLabel();
    b
      ..emitLoadInt(1, 2)
      ..emitABC(Op.ltInt, 1, 0, 1)
      ..emitBranch(Op.jz, 1, elseL)
      ..emitA(Op.ret, 0)
      ..bind(elseL)
      ..emitABx(Op.loadFunc, 1, 0)
      ..emitLoadInt(2, 1)
      ..emitABC(Op.subInt, 2, 0, 2)
      ..emitABC(Op.call, 1, 0, 1)
      ..emitABx(Op.loadFunc, 3, 0)
      ..emitLoadInt(4, 2)
      ..emitABC(Op.subInt, 4, 0, 4)
      ..emitABC(Op.call, 3, 0, 1)
      ..emitABC(Op.addInt, 1, 1, 3)
      ..emitA(Op.ret, 1);
    return Module(
      constants: ConstantPool(),
      functions: [b.toProto(name: 'fib', paramCount: 1, registerCount: 5)],
      entryFunction: 0,
    );
  }

  // sum(n) { var s = 0; for (var i = 0; i < n; i++) s += i; return s; }
  static Module _loopModule() {
    final b = BytecodeBuilder();
    final loop = b.newLabel();
    final done = b.newLabel();
    b
      ..emitLoadInt(1, 0) // s
      ..emitLoadInt(2, 0) // i
      ..emitLoadInt(3, 1) // one
      ..bind(loop)
      ..emitABC(Op.ltInt, 4, 2, 0)
      ..emitBranch(Op.jz, 4, done)
      ..emitABC(Op.addInt, 1, 1, 2)
      ..emitABC(Op.addInt, 2, 2, 3)
      ..emitJmp(loop)
      ..bind(done)
      ..emitA(Op.ret, 1);
    return Module(
      constants: ConstantPool(),
      functions: [b.toProto(name: 'sum', paramCount: 1, registerCount: 5)],
      entryFunction: 0,
    );
  }

  // dispatch(n) { var acc = 0; for (i in 0..n) acc += 'hello'.length; return acc; }
  //
  // Every iteration issues the same `invoke.dyn 'length'` on a String, so the
  // call site's inline cache is monomorphic and hot after the first hit — this
  // measures inline-cache dispatch throughput specifically (brief §6.5, §12).
  static Module _dispatchModule() {
    final constants = ConstantPool();
    final s = constants.add('hello');
    final b = BytecodeBuilder();
    final loop = b.newLabel();
    final done = b.newLabel();
    b
      ..emitLoadInt(1, 0) // acc
      ..emitLoadInt(2, 0) // i
      ..emitLoadInt(3, 1) // one
      ..emitABx(Op.loadConst, 4, s) // receiver 'hello'
      ..bind(loop)
      ..emitABC(Op.ltInt, 5, 2, 0)
      ..emitBranch(Op.jz, 5, done)
      ..emitAB(Op.move, 6, 4) // receiver copy for the call
      ..emitABx(Op.invokeDyn, 6, 0) // R6 = 'hello'.length (inline-cached)
      ..emitABC(Op.addInt, 1, 1, 6) // acc += length
      ..emitABC(Op.addInt, 2, 2, 3) // i++
      ..emitJmp(loop)
      ..bind(done)
      ..emitA(Op.ret, 1);
    return Module(
      constants: constants,
      functions: [b.toProto(name: 'dispatch', paramCount: 1, registerCount: 7)],
      entryFunction: 0,
      callSites: const [CallSite(selector: 'length', argCount: 0)],
    );
  }
}
