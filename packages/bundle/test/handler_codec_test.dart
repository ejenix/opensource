// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bundle/bundle.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_compiler/compiler.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

const _metadata = BundleMetadata(
  targetAppId: 'com.example.app',
  targetFlutterVersion: '3.41.6',
  minSdk: '1.0.0',
);

void main() {
  group('exception-handler serialization (body v6)', () {
    test('a hand-built handler survives an encode/decode round-trip', () {
      final b = BytecodeBuilder();
      final start = b.newLabel();
      final end = b.newLabel();
      final target = b.newLabel();
      b
        ..bind(start)
        ..emitLoadInt(0, 1)
        ..bind(end)
        ..emitA(Op.ret, 0)
        ..bind(target)
        ..emitA(Op.ret, 1)
        ..addHandler(start, end, target, 1);
      final proto = b.toProto(name: 'f', paramCount: 0, registerCount: 2);
      expect(proto.handlers, hasLength(1));

      final module = Module(
        constants: ConstantPool(),
        functions: [proto],
        entryFunction: 0,
      );
      final (decoded, _) = ModuleCodec.decodeBody(
        ModuleCodec.encodeBody(module, _metadata),
      );

      final h = decoded.functions.single.handlers.single;
      final original = proto.handlers.single;
      expect(h.start, original.start);
      expect(h.end, original.end);
      expect(h.target, original.target);
      expect(h.catchReg, original.catchReg);
    });

    test('a compiled try/catch still runs after a round-trip', () async {
      final result = await Compiler().compileSource('''
int main() {
  try {
    throw 21;
  } catch (e) {
    return (e as int) * 2;
  }
}
''');
      expect(result.hasErrors, isFalse);

      final (decoded, _) = ModuleCodec.decodeBody(
        ModuleCodec.encodeBody(result.moduleOrThrow, _metadata),
      );
      // The handler table must survive so the decoded module catches the throw.
      expect(
        decoded.functions.any((f) => f.handlers.isNotEmpty),
        isTrue,
        reason: 'expected at least one function to carry a handler table',
      );
      expect(Interpreter(decoded).run(), 42);
    });
  });
}
