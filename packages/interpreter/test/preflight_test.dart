// Copyright (c) Ejenix authors. MIT license.

/// A patch may only call capabilities the **binary on the device** registers.
/// Adding `@Patchable('App.blogs')` to app source and compiling a patch against
/// the regenerated SDK produces a valid patch that still cannot run on a build
/// released before it — the call failed mid-render with
/// `no host global 'App.blogs'`, after half the screen had been built.
///
/// The requirement set is static, so the gap is knowable before anything runs.
library;

import 'package:ejenix_bytecode/bytecode.dart';
import 'package:ejenix_interpreter/interpreter.dart';
import 'package:test/test.dart';

/// `build() { App.blogs(); }` — one host call, nothing else.
Module _callsHostGlobal(String selector) {
  final f =
      (BytecodeBuilder()
            ..emitABx(Op.invokeStatic, 0, 0)
            ..emitA(Op.ret, 0))
          .toProto(name: 'build', paramCount: 0, registerCount: 2);
  return Module(
    constants: ConstantPool(),
    functions: [f],
    callSites: [CallSite(selector: selector, argCount: 0)],
  );
}

void main() {
  group('missingHostGlobals', () {
    test('names a capability the host does not register', () {
      final registry = HostRegistry.standard();
      expect(missingHostGlobals(_callsHostGlobal('App.blogs'), registry), [
        'App.blogs',
      ]);
    });

    test('is empty once the host registers it', () {
      final registry = HostRegistry.standard()
        ..registerGlobal('App.blogs', (_, _) => const []);
      expect(missingHostGlobals(_callsHostGlobal('App.blogs'), registry), []);
    });

    test('does not flag dynamic method selectors as missing globals', () {
      // The regression that would make this check useless: `invokeDyn` shares
      // the call-site table, and its selectors are ordinary method names
      // resolved by receiver kind. Treating them as globals would reject every
      // healthy patch — `[].length` is not a host global.
      final f =
          (BytecodeBuilder()
                ..emitABx(Op.invokeDyn, 0, 0)
                ..emitA(Op.ret, 0))
              .toProto(name: 'build', paramCount: 0, registerCount: 2);
      final module = Module(
        constants: ConstantPool(),
        functions: [f],
        callSites: [const CallSite(selector: 'length', argCount: 0)],
      );
      expect(missingHostGlobals(module, HostRegistry.standard()), isEmpty);
    });

    test('reports each missing capability once, in first-seen order', () {
      final f =
          (BytecodeBuilder()
                ..emitABx(Op.invokeStatic, 0, 1)
                ..emitABx(Op.invokeStatic, 0, 0)
                ..emitABx(Op.invokeStatic, 0, 1)
                ..emitA(Op.ret, 0))
              .toProto(name: 'build', paramCount: 0, registerCount: 2);
      final module = Module(
        constants: ConstantPool(),
        functions: [f],
        callSites: const [
          CallSite(selector: 'App.first', argCount: 0),
          CallSite(selector: 'App.second', argCount: 0),
        ],
      );
      expect(missingHostGlobals(module, HostRegistry.standard()), [
        'App.second',
        'App.first',
      ]);
    });
  });

  group('registry enumeration', () {
    // The primitive a publish-time gate needs: a build's capability surface as
    // a value that can be written to a file and diffed, rather than a question
    // that can only be asked one name at a time.
    test('globalNames lists what the build can run, sorted', () {
      final r = HostRegistry.standard()
        ..registerGlobal('App.zebra', (_, _) => null)
        ..registerGlobal('App.apple', (_, _) => null);
      final names = r.globalNames;
      expect(names, contains('App.apple'));
      expect(names, contains('App.zebra'));
      expect(names.indexOf('App.apple'), lessThan(names.indexOf('App.zebra')));
      expect(names, equals([...names]..sort()), reason: 'must be stable');
    });

    test('methodNames covers the other half of the allow-list', () {
      final r = HostRegistry.standard()
        ..register('Snapshot', 'hasData', (x, _) => true);
      expect(r.methodNames, contains('Snapshot#hasData'));
    });

    test('a manifest of globalNames answers the publish-time question', () {
      // What CI does: does this bundle need anything the app does not ship?
      final shipped =
          (HostRegistry.standard()..registerGlobal('App.todos', (_, _) => null))
              .globalNames
              .toSet();
      final needs = requiredHostGlobals(_callsHostGlobal('App.blogs'));
      expect(needs.where((n) => !shipped.contains(n)), ['App.blogs']);
    });
  });

  group('requiredHostGlobals', () {
    test('lists what a patch needs, for tooling', () {
      expect(requiredHostGlobals(_callsHostGlobal('App.blogs')), ['App.blogs']);
    });

    test('a patch with no host calls needs nothing', () {
      final f =
          (BytecodeBuilder()
                ..emitLoadInt(0, 7)
                ..emitA(Op.ret, 0))
              .toProto(name: 'build', paramCount: 0, registerCount: 1);
      final module = Module(constants: ConstantPool(), functions: [f]);
      expect(requiredHostGlobals(module), isEmpty);
    });
  });
}
