// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

Future<Module> compile(String source) async {
  final result = await Compiler().compileSource(source);
  if (result.hasErrors) {
    fail('unexpected errors:\n${result.diagnostics.join('\n')}');
  }
  return result.moduleOrThrow;
}

/// The distinct opcodes used by function [name] in [m].
Set<Op> opcodesOf(Module m, String name) {
  final fn = m.functions.firstWhere((f) => f.name == name);
  final ops = <Op>{};
  for (var i = 0; i < fn.code.length; i++) {
    final ins = Instruction(fn.code[i]);
    if (ins.op == Op.pfx) continue;
    ops.add(ins.op);
  }
  return ops;
}

void main() {
  group('constant folding computes the right value', () {
    Future<Object?> run(String expr, {String type = 'int'}) async {
      final m = await compile('$type f() => $expr;');
      return Interpreter(
        m,
      ).callFunction(m.functions.firstWhere((f) => f.name == 'f'), const []);
    }

    test('integer arithmetic and precedence', () async {
      expect(await run('2 + 3 * 4'), 14);
      expect(await run('(2 + 3) * 4'), 20);
      expect(await run('10 - 3'), 7);
      expect(await run('100 * 100'), 10000); // beyond the 16-bit immediate
      expect(await run('7 ~/ 2'), 3);
      expect(await run('17 % 5'), 2);
      expect(await run('-(3 + 4)'), -7);
    });

    test('bitwise folding', () async {
      expect(await run('1 << 4'), 16);
      expect(await run('0xF0 >> 4'), 15);
      expect(await run('0xF0 & 0x0F'), 0);
      expect(await run('5 | 2'), 7);
      expect(await run('~0'), -1);
    });

    test('double and mixed folding', () async {
      expect(await run('10 / 4', type: 'double'), 2.5);
      expect(await run('2.5 * 2', type: 'double'), 5.0);
      expect(await run('1 + 0.5', type: 'double'), 1.5);
    });

    test('boolean and comparison folding', () async {
      expect(await run('2 > 1', type: 'bool'), isTrue);
      expect(await run('1 < 2', type: 'bool'), isTrue);
      expect(await run('3 >= 2', type: 'bool'), isTrue);
      expect(await run('3 <= 2', type: 'bool'), isFalse);
      expect(await run('1 != 2', type: 'bool'), isTrue);
      expect(await run('!(1 == 2)', type: 'bool'), isTrue);
      expect(await run('true && false', type: 'bool'), isFalse);
      expect(await run('true || false', type: 'bool'), isTrue);
      expect(await run('true == true', type: 'bool'), isTrue);
      expect(await run('true != false', type: 'bool'), isTrue);
    });

    test('string folding', () async {
      expect(await run("'a' + 'b' + 'c'", type: 'String'), 'abc');
    });
  });

  group('folding is visible in the emitted bytecode', () {
    test('a constant expression collapses to a single load', () async {
      final m = await compile('int f() => 2 + 3 * 4;');
      // No arithmetic opcodes survive — just a load and a return.
      expect(opcodesOf(m, 'f'), <Op>{Op.loadInt, Op.ret});
    });

    test('a large constant collapses to a pooled load', () async {
      final m = await compile('int f() => 1000 * 1000;');
      // 1000000 exceeds the 16-bit immediate, so it lands in the constant pool.
      expect(opcodesOf(m, 'f'), <Op>{Op.loadConst, Op.ret});
      expect(m.constants.values, contains(1000000));
    });

    test('a non-constant expression is not folded', () async {
      final m = await compile('int f(int a) => a + 3 * 4;');
      // `3 * 4` folds to 12, but the addition with `a` remains.
      expect(opcodesOf(m, 'f'), contains(Op.addInt));
    });
  });

  group('dead-branch elimination (constant conditions)', () {
    Future<Object?> runMain(Module m) => Future.value(Interpreter(m).run());

    test('if (true) keeps only the then-branch', () async {
      final m = await compile('int main() { if (true) return 1; return 2; }');
      expect(await runMain(m), 1);
      // The branch is gone: no conditional jump survives.
      expect(opcodesOf(m, 'main'), isNot(contains(Op.jz)));
    });

    test('if (false) keeps only the else-branch', () async {
      final m = await compile('''
int main() {
  if (1 > 2) {
    return 1;
  } else {
    return 2;
  }
}
''');
      expect(await runMain(m), 2);
      expect(opcodesOf(m, 'main'), isNot(contains(Op.jz)));
    });

    test('a constant ternary selects one arm', () async {
      final m = await compile('int main() => 3 > 2 ? 10 : 20;');
      expect(await runMain(m), 10);
      expect(opcodesOf(m, 'main'), <Op>{Op.loadInt, Op.ret});
    });

    test('while (false) emits nothing', () async {
      final m = await compile('''
int main() {
  var x = 5;
  while (false) { x = x + 1; }
  return x;
}
''');
      expect(await runMain(m), 5);
      expect(opcodesOf(m, 'main'), isNot(contains(Op.jmp)));
    });

    test('a non-constant condition still branches normally', () async {
      final m = await compile(
        'int f(int a) { if (a > 0) return 1; return 2; }',
      );
      expect(opcodesOf(m, 'f'), contains(Op.jz));
    });
  });

  group('folding never changes runtime semantics of a fault', () {
    test('constant integer division by zero still throws at runtime', () async {
      // `5 ~/ 0` must NOT be folded away; the VM reproduces the fault.
      final m = await compile('int f() => 5 ~/ 0;');
      expect(opcodesOf(m, 'f'), contains(Op.divInt));
      expect(
        () => Interpreter(
          m,
        ).callFunction(m.functions.firstWhere((f) => f.name == 'f'), const []),
        throwsA(isA<InterpreterException>()),
      );
    });
  });
}
