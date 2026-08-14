// Copyright (c) Ejenix authors. MIT license.

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

void main() {
  group('HostRegistry', () {
    final registry = HostRegistry.standard();

    test('kind chain is most-specific first, ending in Object', () {
      expect(HostRegistry.kindsOf(1), ['int', 'num', 'Object']);
      expect(HostRegistry.kindsOf(1.0), ['double', 'num', 'Object']);
      expect(HostRegistry.kindsOf('x'), ['String', 'Object']);
      expect(HostRegistry.kindsOf(<int>[]), ['List', 'Iterable', 'Object']);
      expect(HostRegistry.kindsOf(<int>{}), ['Set', 'Iterable', 'Object']);
      expect(HostRegistry.kindsOf(null), ['Null', 'Object']);
    });

    test('resolves selectors with inheritance fallback', () {
      expect(registry.resolve('hi', 'length')!('hi', const []), 2);
      expect(registry.resolve(5, 'abs')!(-5, const []), 5); // num on int
      expect(registry.resolve(5, 'toString')!(5, const []), '5'); // Object
      expect(registry.resolve('x', 'nope'), isNull);
    });

    test('an empty registry allows nothing', () {
      expect(HostRegistry().resolve('x', 'length'), isNull);
    });

    Object? call(
      Object? receiver,
      String selector, [
      List<Object?> a = const [],
    ]) => registry.resolve(receiver, selector)!(receiver, a);

    test('resolves and invokes host globals', () {
      expect(registry.resolveGlobal('identical')!(null, [1, 1]), isTrue);
      expect(registry.resolveGlobal('print'), isNotNull);
      expect(registry.resolveGlobal('nope'), isNull);
    });

    test('string methods with arguments', () {
      expect(call('hello', 'substring', [1]), 'ello');
      expect(call('hello', 'startsWith', ['he']), isTrue);
      expect(call('a,b', 'replaceAll', [',', ';']), 'a;b');
      expect(call('a', 'compareTo', ['b']), lessThan(0));
      expect(call('5', 'padLeft', [3]), '  5');
      expect(call('5', 'padLeft', [3, '0']), '005');
      expect(call('5', 'padRight', [3, '.']), '5..');
    });

    test('numeric formatting methods', () {
      expect(call(255, 'toRadixString', [16]), 'ff');
      expect(call(3.14159, 'toStringAsFixed', [2]), '3.14');
    });

    test('list slicing and joining', () {
      expect(call([1, 2, 3, 4], 'sublist', [1]), [2, 3, 4]);
      expect(call([1, 2, 3, 4], 'sublist', [1, 3]), [2, 3]);
      expect(call([1, 2, 3], 'join', ['-']), '1-2-3');
      expect(call([1, 2, 3], 'join'), '123');
    });

    group('higher-order methods take Dart callbacks', () {
      final xs = [1, 2, 3, 4];
      test('map / where / expand materialize to lists', () {
        expect(call(xs, 'map', [(Object? e) => (e as int) * 2]), [2, 4, 6, 8]);
        expect(call(xs, 'where', [(Object? e) => (e as int).isEven]), [2, 4]);
        expect(
          call(
            [1, 2],
            'expand',
            [
              (Object? e) => [e, e],
            ],
          ),
          [1, 1, 2, 2],
        );
      });

      test('forEach visits every element', () {
        final seen = <Object?>[];
        call(xs, 'forEach', [(Object? e) => seen.add(e)]);
        expect(seen, [1, 2, 3, 4]);
      });

      test('any / every / firstWhere test with a predicate', () {
        expect(call(xs, 'any', [(Object? e) => (e as int) > 3]), isTrue);
        expect(call(xs, 'every', [(Object? e) => (e as int) > 0]), isTrue);
        expect(call(xs, 'firstWhere', [(Object? e) => (e as int) > 2]), 3);
      });

      test('fold / reduce accumulate', () {
        expect(
          call(xs, 'fold', [
            0,
            (Object? a, Object? b) => (a as int) + (b as int),
          ]),
          10,
        );
        expect(
          call(xs, 'reduce', [
            (Object? a, Object? b) => (a as int) + (b as int),
          ]),
          10,
        );
      });

      test('takeWhile / skipWhile split the sequence', () {
        expect(call(xs, 'takeWhile', [(Object? e) => (e as int) < 3]), [1, 2]);
        expect(call(xs, 'skipWhile', [(Object? e) => (e as int) < 3]), [3, 4]);
      });

      test('sort with and without a comparator', () {
        expect(call([3, 1, 2], 'sort'), isNull); // natural order, in place
        final descending = [1, 2, 3];
        call(descending, 'sort', [
          (Object? a, Object? b) => (b as int) - (a as int),
        ]);
        expect(descending, [3, 2, 1]);
      });

      test('Set exposes the same higher-order methods', () {
        expect(call(<int>{1, 2, 3}, 'map', [(Object? e) => (e as int) * 10]), [
          10,
          20,
          30,
        ]);
        expect(
          call(<int>{1, 2, 3}, 'any', [(Object? e) => (e as int) > 2]),
          isTrue,
        );
      });
    });

    test('Map read helpers', () {
      final m = {'a': 1, 'b': 2};
      expect(call(m, 'containsKey', ['a']), isTrue);
      expect(call(m, 'containsValue', [2]), isTrue);
      expect(call(m, 'keys', const []), ['a', 'b']);
      expect(call(m, 'values', const []), [1, 2]);
      expect(call(m, 'remove', ['a']), 1);
    });
  });

  group('invoke.dyn end-to-end', () {
    test('string method with arguments', () {
      final constants = ConstantPool();
      final k = constants.add('hello world');
      final fn =
          (BytecodeBuilder()
                ..emitABx(Op.loadConst, 0, k)
                ..emitLoadInt(1, 0)
                ..emitLoadInt(2, 5)
                ..emitABx(Op.invokeDyn, 0, 0) // R0.substring(R1, R2)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 3);
      final module = Module(
        constants: constants,
        functions: [fn],
        entryFunction: 0,
        callSites: const [CallSite(selector: 'substring', argCount: 2)],
      );
      expect(Interpreter(module).run(), 'hello');
    });

    test('build a list, mutate it, and read its length', () {
      // list = []; list.add(42); return list.length;  (receiver kept in R0)
      final fn =
          (BytecodeBuilder()
                ..emitA(Op.listNew, 0) // R0 = []
                ..emitAB(Op.move, 1, 0) // R1 = receiver copy
                ..emitLoadInt(2, 42) // R2 = 42
                ..emitABx(Op.invokeDyn, 1, 0) // R1 = R0.add(42) (void)
                ..emitAB(Op.move, 1, 0) // R1 = receiver copy
                ..emitABx(Op.invokeDyn, 1, 1) // R1 = R0.length
                ..emitA(Op.ret, 1))
              .toProto(name: 'main', paramCount: 0, registerCount: 3);
      final module = Module(
        constants: ConstantPool(),
        functions: [fn],
        entryFunction: 0,
        callSites: const [
          CallSite(selector: 'add', argCount: 1),
          CallSite(selector: 'length', argCount: 0),
        ],
      );
      expect(Interpreter(module).run(), 1);
    });

    test('unknown selector faults with a typed exception', () {
      final constants = ConstantPool();
      final k = constants.add('x');
      final fn =
          (BytecodeBuilder()
                ..emitABx(Op.loadConst, 0, k)
                ..emitABx(Op.invokeDyn, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'main', paramCount: 0, registerCount: 1);
      final module = Module(
        constants: constants,
        functions: [fn],
        entryFunction: 0,
        callSites: const [CallSite(selector: 'frobnicate', argCount: 0)],
      );
      expect(
        () => Interpreter(module).run(),
        throwsA(
          isA<InterpreterException>().having(
            (e) => e.message,
            'message',
            contains('no host method'),
          ),
        ),
      );
    });
  });

  group('inline cache', () {
    // f(x) => x.toString();  one call site exercised with many receiver types.
    final fn =
        (BytecodeBuilder()
              ..emitABx(Op.invokeDyn, 0, 0)
              ..emitA(Op.ret, 0))
            .toProto(name: 'f', paramCount: 1, registerCount: 1);
    final module = Module(
      constants: ConstantPool(),
      functions: [fn],
      entryFunction: 0,
      callSites: const [CallSite(selector: 'toString', argCount: 0)],
    );

    test('caches monomorphic, then polymorphic, then megamorphic', () {
      final interp = Interpreter(module);
      expect(interp.callFunction(fn, [42]), '42'); // monomorphic (int)
      expect(interp.callFunction(fn, ['hi']), 'hi'); // polymorphic (+String)
      expect(interp.callFunction(fn, [true]), 'true'); // +bool
      expect(interp.callFunction(fn, [3.5]), '3.5'); // +double
      expect(interp.callFunction(fn, [<int>[]]), '[]'); // +List -> megamorphic
      expect(interp.callFunction(fn, [42]), '42'); // megamorphic path
      expect(interp.callFunction(fn, [<int>{}]), '{}'); // megamorphic (Set)
    });
  });

  group('kind resolvers (types owned by a host integration)', () {
    test('a host object gets methods through a registered kind', () {
      final r = HostRegistry.standard()
        ..addKindResolver((o) => o is _Ctrl ? 'Ctrl' : null)
        ..register('Ctrl', 'text', (recv, _) => (recv as _Ctrl).text)
        ..register('Ctrl', 'clear', (recv, _) {
          (recv as _Ctrl).text = '';
          return null;
        });

      final ctrl = _Ctrl('hello');
      expect(r.resolve(ctrl, 'text')!(ctrl, const []), 'hello');
      r.resolve(ctrl, 'clear')!(ctrl, const []);
      expect(ctrl.text, '');
    });

    test('a resolved kind still falls back to Object handlers', () {
      final r = HostRegistry.standard()
        ..addKindResolver((o) => o is _Ctrl ? 'Ctrl' : null);
      // `Ctrl` binds no `toString`, so the Object handler answers...
      expect(r.resolve(_Ctrl('a'), 'toString'), isNotNull);
      // ...but an unregistered selector is still denied: naming a kind does
      // not widen the sandbox.
      expect(r.resolve(_Ctrl('a'), 'text'), isNull);
    });

    test('a resolver that does not recognize the receiver is skipped', () {
      final r = HostRegistry.standard()
        ..addKindResolver((o) => o is _Ctrl ? 'Ctrl' : null)
        ..register('Ctrl', 'text', (_, _) => 'never');
      // A String is not a _Ctrl, so the built-in chain answers as usual.
      expect(r.resolve('hi', 'length')!('hi', const []), 2);
      expect(r.resolve('hi', 'text'), isNull);
    });

    test('resolvers are searched before the built-in chain', () {
      final r = HostRegistry.standard()
        ..addKindResolver((o) => o is List ? 'Frozen' : null)
        ..register('Frozen', 'length', (_, _) => -1);
      expect(r.resolve(<int>[1, 2], 'length')!(<int>[1, 2], const []), -1);
    });
  });
}

/// Stands in for an object a host integration owns (e.g. Flutter's
/// `TextEditingController`), which the built-in kind chain knows nothing about.
class _Ctrl {
  _Ctrl(this.text);
  String text;
}
