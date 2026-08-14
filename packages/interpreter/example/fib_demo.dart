import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';

void main() {
  // fib(n) = n < 2 ? n : fib(n-1) + fib(n-2)  — hand-assembled.
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
  final fib = b.toProto(name: 'fib', paramCount: 1, registerCount: 5);
  final module = Module(
    constants: ConstantPool(),
    functions: [fib],
    entryFunction: 0,
  );

  print(Disassembler.disassemble(module));

  final profile = OpProfile();
  final interp = Interpreter(module, profile: profile);
  for (final n in [0, 1, 10, 20, 25]) {
    print('fib($n) = ${interp.run([n])}');
  }
  print(
    '\nhot opcodes: '
    '${profile.hottest(3).map((e) => "${e.key.mnemonic}=${e.value}").join(", ")}',
  );
}
