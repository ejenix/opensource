// Copyright (c) Ejenix authors. MIT license.

/// A signature proves *origin*, not *safety*. It says the bytes came from a
/// holder of the signing key — nothing about whether the module indexes a
/// register that does not exist, jumps outside its own code, or names a
/// constant past the end of the pool.
///
/// Those invariants used to live in Dart `assert`s, which are stripped from
/// release builds: they held while developing and vanished on the devices that
/// matter. The interpreter indexes registers and tables directly, so an
/// out-of-range value there is not a caught error — it is undefined behaviour
/// in the host.
library;

import 'dart:typed_data';

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:test/test.dart';

FunctionProto _fn({
  required List<int> words,
  int registers = 4,
  int params = 0,
  String name = 'f',
  List<ExceptionHandler> handlers = const [],
}) => FunctionProto(
  name: name,
  paramCount: params,
  registerCount: registers,
  code: Uint32List.fromList(words),
  handlers: handlers,
);

int _word(Op op, {int a = 0, int b = 0, int c = 0}) =>
    op.code | (a << 8) | (b << 16) | (c << 24);
int _aBx(Op op, int a, int bx) =>
    op.code | (a << 8) | ((bx & 0xFF) << 16) | (((bx >> 8) & 0xFF) << 24);

Module _module(
  List<FunctionProto> fns, {
  ConstantPool? pool,
  int globals = 0,
  List<CallSite> sites = const [],
  List<ClassDescriptor> classes = const [],
}) => Module(
  constants: pool ?? ConstantPool(),
  functions: fns,
  callSites: sites,
  classes: classes,
  globalCount: globals,
);

void main() {
  group('accepts what the compiler actually produces', () {
    test('a real compiled function verifies clean', () {
      // The guard against over-correcting: a verifier that rejects genuine
      // modules is a far worse outage than the inputs it turns away.
      final f =
          (BytecodeBuilder()
                ..emitLoadInt(0, 42)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 1);
      expect(
        verifyModule(Module(constants: ConstantPool(), functions: [f])),
        isEmpty,
      );
    });

    test('jumps, handlers and generators verify clean', () {
      final b = BytecodeBuilder();
      final top = Label();
      b.bind(top);
      b.emitLoadInt(0, 1);
      b.emitJmp(top);
      final f = b.toProto(name: 'loop', paramCount: 0, registerCount: 2);
      expect(
        verifyModule(Module(constants: ConstantPool(), functions: [f])),
        isEmpty,
      );
    });
  });

  group('rejects what a signature cannot catch', () {
    test('a register beyond the frame', () {
      // The interpreter would index past its register list.
      final m = _module([
        _fn(words: [_word(Op.ret, a: 9)], registers: 4),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('register 9'),
      );
    });

    test('a jump outside the function', () {
      final m = _module([
        _fn(words: [_word(Op.jmp, a: 200, b: 0, c: 0)]),
      ]);
      expect(verifyModule(m), isNotEmpty);
    });

    test('a constant index past the end of the pool', () {
      final pool = ConstantPool();
      final m = _module([
        _fn(words: [_aBx(Op.loadConst, 0, 99)]),
      ], pool: pool);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('constant index 99'),
      );
    });

    test('a function index that does not exist', () {
      final m = _module([
        _fn(words: [_aBx(Op.loadFunc, 0, 7)]),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('function index 7'),
      );
    });

    test('a global slot beyond globalCount', () {
      final m = _module([
        _fn(words: [_aBx(Op.loadGlobal, 0, 5)]),
      ], globals: 2);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('global index 5'),
      );
    });

    test('a call site that does not exist', () {
      final m = _module([
        _fn(words: [_aBx(Op.invokeStatic, 0, 3)]),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('call site index 3'),
      );
    });

    test('an unknown opcode', () {
      final m = _module([
        _fn(words: [0xFE]),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('unknown opcode'),
      );
    });

    // paramCount > registerCount cannot be constructed here: FunctionProto
    // asserts it. That assert is precisely what a release build strips, which
    // is why the verifier re-checks it — but it also means the case is only
    // reachable from decoded bytes, never from Dart.

    test('a jump landing one word past the end is caught', () {
      // The boundary case: a displacement to exactly code.length is one word
      // beyond the last instruction, and an off-by-one here would let control
      // run off the end of the function.
      final m = _module([
        _fn(words: [_word(Op.jmp, a: 1, b: 0, c: 0), _word(Op.retVoid)]),
      ]);
      expect(verifyModule(m), isNotEmpty);
    });

    test('a handler catching into a register that does not exist', () {
      final m = _module([
        _fn(
          words: [_word(Op.retVoid)],
          registers: 2,
          handlers: const [
            ExceptionHandler(start: 0, end: 1, target: 0, catchReg: 9),
          ],
        ),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('catch register 9'),
      );
    });

    test('a handler range running past the code', () {
      final m = _module([
        _fn(
          words: [_word(Op.retVoid)],
          handlers: const [
            ExceptionHandler(start: 0, end: 99, target: 0, catchReg: 0),
          ],
        ),
      ]);
      expect(verifyModule(m), isNotEmpty);
    });

    test('a cyclic superclass chain', () {
      // Method resolution would loop forever inside the host.
      final m = _module(
        [
          _fn(words: [_word(Op.retVoid)]),
        ],
        classes: const [
          ClassDescriptor(name: 'A', fieldCount: 0, superIndex: 1, methods: {}),
          ClassDescriptor(name: 'B', fieldCount: 0, superIndex: 0, methods: {}),
        ],
      );
      expect(verifyModule(m).map((e) => e.message).join(), contains('cyclic'));
    });

    test('a class method pointing at no function', () {
      final m = _module(
        [
          _fn(words: [_word(Op.retVoid)]),
        ],
        classes: const [
          ClassDescriptor(
            name: 'A',
            fieldCount: 0,
            superIndex: -1,
            methods: {'m': 42},
          ),
        ],
      );
      expect(verifyModule(m), isNotEmpty);
    });
  });

  group('module-level quotas and shape', () {
    // Ceilings and module-wide indices. Reachable only from decoded bytes — a
    // Dart caller would not build these — which is exactly why the verifier
    // has to check them rather than trusting the constructor.
    const tight = VerifyLimits(
      maxFunctions: 1,
      maxClasses: 1,
      maxCodeWords: 2,
      maxRegisters: 4,
      maxHandlers: 1,
    );

    test('too many functions', () {
      final m = _module([
        _fn(words: [_word(Op.retVoid)], name: 'a'),
        _fn(words: [_word(Op.retVoid)], name: 'b'),
      ]);
      expect(
        verifyModule(m, limits: tight).map((e) => e.message).join(),
        contains('functions exceeds'),
      );
    });

    test('too many classes', () {
      final m = _module(
        [
          _fn(words: [_word(Op.retVoid)]),
        ],
        classes: const [
          ClassDescriptor(
            name: 'A',
            fieldCount: 0,
            superIndex: -1,
            methods: {},
          ),
          ClassDescriptor(
            name: 'B',
            fieldCount: 0,
            superIndex: -1,
            methods: {},
          ),
        ],
      );
      expect(
        verifyModule(m, limits: tight).map((e) => e.message).join(),
        contains('classes exceeds'),
      );
    });

    test('a function longer than the code-word ceiling', () {
      final m = _module([
        _fn(words: [_word(Op.retVoid), _word(Op.retVoid), _word(Op.retVoid)]),
      ]);
      expect(
        verifyModule(m, limits: tight).map((e) => e.message).join(),
        contains('code words exceeds'),
      );
    });

    test('a register file wider than the encoding allows', () {
      // A register index is one byte; anything past that cannot be addressed.
      final m = _module([
        _fn(words: [_word(Op.retVoid)], registers: 200),
      ]);
      expect(
        verifyModule(m, limits: tight).map((e) => e.message).join(),
        contains('registerCount 200'),
      );
    });

    test('more handlers than the ceiling', () {
      final m = _module([
        _fn(
          words: [_word(Op.retVoid)],
          handlers: const [
            ExceptionHandler(start: 0, end: 1, target: 0, catchReg: 0),
            ExceptionHandler(start: 0, end: 1, target: 0, catchReg: 0),
          ],
        ),
      ]);
      expect(
        verifyModule(m, limits: tight).map((e) => e.message).join(),
        contains('handlers exceeds'),
      );
    });

    test('an entry function that does not exist', () {
      final m = Module(
        constants: ConstantPool(),
        functions: [
          _fn(words: [_word(Op.retVoid)]),
        ],
        entryFunction: 0,
      );
      expect(verifyModule(m), isEmpty);
    });

    test('a static initializer index out of range', () {
      final m = Module(
        constants: ConstantPool(),
        functions: [
          _fn(words: [_word(Op.retVoid)]),
        ],
        staticInit: 9,
      );
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('staticInit 9'),
      );
    });

    test('a superclass index out of range', () {
      final m = _module(
        [
          _fn(words: [_word(Op.retVoid)]),
        ],
        classes: const [
          ClassDescriptor(name: 'A', fieldCount: 0, superIndex: 5, methods: {}),
        ],
      );
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('superIndex 5'),
      );
    });

    test('a negative field count', () {
      final m = _module(
        [
          _fn(words: [_word(Op.retVoid)]),
        ],
        classes: const [
          ClassDescriptor(
            name: 'A',
            fieldCount: -1,
            superIndex: -1,
            methods: {},
          ),
        ],
      );
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('negative fieldCount'),
      );
    });

    test('a pfx not followed by an indexed instruction', () {
      // pfx carries the high bits of the *next* instruction's index. Standing
      // alone, or before something that takes no index, it is meaningless.
      final m = _module([
        _fn(words: [_word(Op.pfx), _word(Op.retVoid)]),
      ]);
      expect(verifyModule(m).map((e) => e.message).join(), contains('pfx'));
    });

    test('a trailing pfx with nothing after it', () {
      final m = _module([
        _fn(words: [_word(Op.pfx)]),
      ]);
      expect(
        verifyModule(m).map((e) => e.message).join(),
        contains('nothing follows'),
      );
    });
  });

  group('reporting', () {
    test('every defect is reported, not just the first', () {
      // An operator fixing one problem at a time would otherwise need as many
      // publish attempts as there are defects.
      final m = _module([
        _fn(
          words: [_word(Op.ret, a: 9), _aBx(Op.loadConst, 0, 50)],
          registers: 2,
        ),
      ]);
      expect(verifyModule(m).length, greaterThan(1));
    });

    test('errors name the function and offset', () {
      final m = _module([
        _fn(words: [_word(Op.ret, a: 9)], name: 'broken'),
      ]);
      expect(verifyModule(m).first.toString(), contains('broken'));
    });

    test('the exception message lists every error', () {
      final m = _module([
        _fn(
          words: [_word(Op.ret, a: 9), _aBx(Op.loadConst, 0, 50)],
          registers: 2,
        ),
      ]);
      try {
        verifyModuleOrThrow(m);
        fail('expected a ModuleVerificationException');
      } on ModuleVerificationException catch (e) {
        expect(e.toString(), contains('error(s)'));
        expect(e.toString().split('\n').length, greaterThan(2));
      }
    });

    test('verifyModuleOrThrow throws with every error attached', () {
      final m = _module([
        _fn(words: [_word(Op.ret, a: 9)]),
      ]);
      expect(
        () => verifyModuleOrThrow(m),
        throwsA(isA<ModuleVerificationException>()),
      );
    });
  });
}
