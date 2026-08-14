// Copyright (c) Ejenix authors. MIT license.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';

/// A counter patch, hand-built as the compiler would lower it:
///
///   List createState() => [0];              // persistent state
///   Widget build(s) => ElevatedButton(
///     onPressed: () { s[0] = s[0] + 1; setState(); },
///     child: Text(s[0].toString()),
///   );
///
/// State lives in a host `List` so it survives rebuilds; the button mutates it
/// and calls `setState`, which the bridge turns into a real Flutter rebuild.
Module _counterModule() {
  final k = ConstantPool();
  final kData = k.add('data');
  final kChild = k.add('child');
  final kOnPressed = k.add('onPressed');

  const site = [
    CallSite(selector: 'add', argCount: 1), // 0
    CallSite(selector: '[]', argCount: 1), // 1
    CallSite(selector: 'toString', argCount: 0), // 2
    CallSite(selector: '[]=', argCount: 2), // 3
    CallSite(selector: 'Text', argCount: 1), // 4
    CallSite(selector: 'ElevatedButton', argCount: 1), // 5
    CallSite(selector: 'setState', argCount: 0), // 6
  ];

  // createState() => <Object?>[0]
  final createState =
      (BytecodeBuilder()
            ..emitA(Op.listNew, 0) // R0 = []
            ..emitAB(Op.move, 1, 0) // receiver copy
            ..emitLoadInt(2, 0) // arg = 0
            ..emitABx(Op.invokeDyn, 1, 0) // R0.add(0)
            ..emitA(Op.ret, 0))
          .toProto(name: 'createState', paramCount: 0, registerCount: 3);

  // The onPressed closure: captures the state list (upvalue 0).
  final onPressed =
      (BytecodeBuilder()
            ..emitABx(Op.upvalGet, 0, 0) // R0 = state cell
            ..emitAB(Op.cellGet, 0, 0) // R0 = the list
            ..emitAB(Op.move, 1, 0) // receiver copy
            ..emitLoadInt(2, 0) // index 0
            ..emitABx(Op.invokeDyn, 1, 1) // R1 = s[0]
            ..emitLoadInt(2, 1)
            ..emitABC(Op.addInt, 1, 1, 2) // R1 = s[0] + 1
            ..emitAB(Op.move, 2, 0) // receiver = list
            ..emitLoadInt(3, 0) // index 0
            ..emitAB(Op.move, 4, 1) // value = s[0] + 1
            ..emitABx(Op.invokeDyn, 2, 3) // s[0] = s[0] + 1
            ..emitABx(Op.invokeStatic, 2, 6) // setState()
            ..emitNone(Op.retVoid))
          .toProto(
            name: '<closure>',
            paramCount: 0,
            registerCount: 5,
            captures: const [0],
          );

  // build(s): read s[0].toString() into a Text, wrap in a button.
  final build =
      (BytecodeBuilder()
            ..emitA(
              Op.cellNew,
              0,
            ) // box the state param so the closure captures it
            ..emitAB(Op.cellGet, 1, 0) // R1 = the list
            ..emitAB(Op.move, 2, 1) // receiver copy
            ..emitLoadInt(3, 0) // index 0
            ..emitABx(Op.invokeDyn, 2, 1) // R2 = s[0]
            ..emitAB(Op.move, 3, 2)
            ..emitABx(Op.invokeDyn, 3, 2) // R3 = s[0].toString()
            // Text({data: R3})
            ..emitA(Op.mapNew, 4)
            ..emitAB(Op.move, 5, 4)
            ..emitABx(Op.loadConst, 6, kData)
            ..emitAB(Op.move, 7, 3)
            ..emitABx(Op.invokeDyn, 5, 3) // map['data'] = string
            ..emitABx(Op.invokeStatic, 4, 4) // R4 = Text(...)
            // ElevatedButton({child: Text, onPressed: closure})
            ..emitA(Op.mapNew, 5)
            ..emitAB(Op.move, 6, 5)
            ..emitABx(Op.loadConst, 7, kChild)
            ..emitAB(Op.move, 8, 4)
            ..emitABx(Op.invokeDyn, 6, 3) // map['child'] = Text
            ..emitAB(Op.move, 6, 5)
            ..emitABx(Op.loadConst, 7, kOnPressed)
            ..emitABx(Op.closureNew, 8, 1) // R8 = onPressed (captures R0)
            ..emitABx(Op.invokeDyn, 6, 3) // map['onPressed'] = closure
            ..emitABx(Op.invokeStatic, 5, 5) // R5 = ElevatedButton(...)
            ..emitA(Op.ret, 5))
          .toProto(name: 'build', paramCount: 1, registerCount: 9);

  return Module(
    constants: k,
    functions: [createState, onPressed, build],
    callSites: site,
  );
}

void main() {
  testWidgets('interpreted setState persists state and rebuilds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InterpretedView(module: _counterModule())),
      ),
    );

    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
  });
}
