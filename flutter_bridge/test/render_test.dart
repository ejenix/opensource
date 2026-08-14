// Copyright (c) Ejenix authors. MIT license.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_flutter/ejenix_flutter.dart';

/// Builds a module whose `build()` returns
/// `Column(children: [Text(a), Text(b)])` — the exact host-call shape (each
/// widget constructor invoked with a `{parameterName: value}` map) the compiler
/// emits for that source. Kept analyzer-free so it runs under the Flutter SDK.
Module _twoTextColumn(String a, String b) {
  final k = ConstantPool();
  final kData = k.add('data');
  final kChildren = k.add('children');
  final kA = k.add(a);
  final kB = k.add(b);

  const site = [
    CallSite(selector: '[]=', argCount: 2), // 0
    CallSite(selector: 'add', argCount: 1), // 1
    CallSite(selector: 'Text', argCount: 1), // 2
    CallSite(selector: 'Column', argCount: 1), // 3
  ];

  final b0 = BytecodeBuilder()..emitA(Op.listNew, 0); // R0 = children

  void appendText(int textConst) {
    b0
      ..emitA(Op.mapNew, 1) // R1 = {}
      ..emitAB(Op.move, 2, 1) // receiver copy
      ..emitABx(Op.loadConst, 3, kData)
      ..emitABx(Op.loadConst, 4, textConst)
      ..emitABx(Op.invokeDyn, 2, 0) // R1['data'] = text
      ..emitABx(Op.invokeStatic, 1, 2) // R1 = Text({data: text})
      ..emitAB(Op.move, 2, 0) // receiver = children
      ..emitAB(Op.move, 3, 1) // arg = the Text
      ..emitABx(Op.invokeDyn, 2, 1); // children.add(Text)
  }

  appendText(kA);
  appendText(kB);

  b0
    ..emitA(Op.mapNew, 1) // R1 = {}
    ..emitAB(Op.move, 2, 1)
    ..emitABx(Op.loadConst, 3, kChildren)
    ..emitAB(Op.move, 4, 0) // val = children list
    ..emitABx(Op.invokeDyn, 2, 0) // R1['children'] = children
    ..emitABx(Op.invokeStatic, 1, 3) // R1 = Column({children: ...})
    ..emitA(Op.ret, 1);

  return Module(
    constants: k,
    functions: [b0.toProto(name: 'build', paramCount: 0, registerCount: 5)],
    callSites: site,
  );
}

void main() {
  testWidgets('an interpreted patch renders a real Flutter widget tree', (
    tester,
  ) async {
    final module = _twoTextColumn('Hello from a patch', 'rendered by the VM');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InterpretedView(module: module)),
      ),
    );

    // The interpreted build() produced genuine framework widgets.
    expect(find.text('Hello from a patch'), findsOneWidget);
    expect(find.text('rendered by the VM'), findsOneWidget);
    expect(find.byType(Column), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(2));
  });

  testWidgets('an interpreted button callback re-enters the VM without error', (
    tester,
  ) async {
    // build() {
    //   var taps = 0;                          // captured cell
    //   return ElevatedButton(onPressed: () { taps = taps + 1; }, child: Text('tap me'));
    // }
    final k = ConstantPool();
    final kOnPressed = k.add('onPressed');
    final kChild = k.add('child');
    final kData = k.add('data');
    final kLabel = k.add('tap me');

    const site = [
      CallSite(selector: '[]=', argCount: 2), // 0
      CallSite(selector: 'Text', argCount: 1), // 1
      CallSite(selector: 'ElevatedButton', argCount: 1), // 2
    ];

    // The onPressed closure: captures `taps` (upvalue 0), increments it.
    final onPressed =
        (BytecodeBuilder()
              ..emitABx(Op.upvalGet, 0, 0) // R0 = taps cell
              ..emitAB(Op.cellGet, 1, 0)
              ..emitLoadInt(2, 1)
              ..emitABC(Op.addInt, 1, 1, 2)
              ..emitAB(Op.cellSet, 0, 1)
              ..emitNone(Op.retVoid))
            .toProto(
              name: '<closure>',
              paramCount: 0,
              registerCount: 3,
              captures: const [0],
            );

    final build =
        (BytecodeBuilder()
              ..emitLoadInt(0, 0) // R0 = taps
              ..emitA(Op.cellNew, 0) // box it (captured)
              // child Text('tap me') in R1
              ..emitA(Op.mapNew, 1)
              ..emitAB(Op.move, 2, 1)
              ..emitABx(Op.loadConst, 3, kData)
              ..emitABx(Op.loadConst, 4, kLabel)
              ..emitABx(Op.invokeDyn, 2, 0) // R1['data'] = 'tap me'
              ..emitABx(Op.invokeStatic, 1, 1) // R1 = Text(...)
              // button map {onPressed: closure, child: R1} in R2
              ..emitA(Op.mapNew, 2)
              ..emitAB(Op.move, 3, 2)
              ..emitABx(Op.loadConst, 4, kOnPressed)
              ..emitABx(
                Op.closureNew,
                5,
                1,
              ) // R5 = onPressed closure (captures R0)
              ..emitABx(Op.invokeDyn, 3, 0) // R2['onPressed'] = closure
              ..emitAB(Op.move, 3, 2)
              ..emitABx(Op.loadConst, 4, kChild)
              ..emitAB(Op.move, 5, 1) // child = Text
              ..emitABx(Op.invokeDyn, 3, 0) // R2['child'] = Text
              ..emitABx(Op.invokeStatic, 2, 2) // R2 = ElevatedButton(...)
              ..emitA(Op.ret, 2))
            .toProto(name: 'build', paramCount: 0, registerCount: 6);

    final module = Module(
      constants: k,
      functions: [build, onPressed],
      callSites: site,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InterpretedView(module: module)),
      ),
    );
    expect(find.text('tap me'), findsOneWidget);
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    // The tap re-entered the interpreter (invokeClosure) with no error.
  });
}
