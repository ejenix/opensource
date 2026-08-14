// Copyright (c) Ejenix authors. MIT license.

import 'constant_pool.dart';
import 'function_proto.dart';

/// A dynamic-dispatch call site: the method [selector] to invoke and the number
/// of positional arguments. `invoke.dyn Bx` indexes the module's call-site
/// table, giving each site a stable slot for its inline cache.
class CallSite {
  const CallSite({required this.selector, required this.argCount});

  /// The method or getter name (a getter has [argCount] `0`).
  final String selector;

  /// The number of positional arguments passed after the receiver.
  final int argCount;
}

/// A compiled class: its field layout, superclass link, and virtual method
/// table. `alloc Bx` creates an instance whose field array has [fieldCount]
/// slots; `invoke.dyn` on an instance resolves a selector through [methods] and,
/// on a miss, up the [superIndex] chain.
class ClassDescriptor {
  const ClassDescriptor({
    required this.name,
    required this.fieldCount,
    required this.superIndex,
    required this.methods,
    this.fields = const {},
  });

  /// The class name (for diagnostics).
  final String name;

  /// Total instance field slots, including inherited fields.
  final int fieldCount;

  /// Index of the superclass in `Module.classes`, or `-1` if none.
  final int superIndex;

  /// Method selectors declared on this class, mapping to module function
  /// indices. Inherited methods are resolved by walking [superIndex].
  final Map<String, int> methods;

  /// Field-name to slot index, so dynamic getters can read a field by name.
  final Map<String, int> fields;
}

/// A self-contained unit of compiled code: the shared constant pool plus the
/// module's functions, classes, call sites, and its entry point.
///
/// This is the in-memory representation the compiler emits and the interpreter
/// executes. Its serialized, signed form is the bundle (`packages/bundle`); a
/// [Module] is what a bundle body decodes to.
class Module {
  /// Creates a module.
  ///
  /// [entryFunction] must be a valid index into [functions] (or `-1` for a
  /// library module with no entry point).
  Module({
    required this.constants,
    required this.functions,
    this.entryFunction = -1,
    this.callSites = const [],
    this.classes = const [],
    this.globalCount = 0,
    this.staticInit = -1,
  }) : assert(
         entryFunction == -1 ||
             (entryFunction >= 0 && entryFunction < functions.length),
         'entryFunction $entryFunction out of range '
         '(functions: ${functions.length})',
       );

  /// The constant pool shared by every function in the module.
  final ConstantPool constants;

  /// The module's functions. `load.func Bx` and `call` reference these by
  /// index.
  final List<FunctionProto> functions;

  /// The dynamic-dispatch call sites, indexed by `invoke.dyn`.
  final List<CallSite> callSites;

  /// The module's classes, indexed by `alloc`.
  final List<ClassDescriptor> classes;

  /// The index of the entry-point function in [functions], or `-1` if none.
  final int entryFunction;

  /// The number of module-level global slots — one per static field, addressed
  /// by `load.global` / `store.global`.
  final int globalCount;

  /// The index of the static-initializer function (run once before the entry to
  /// populate the globals), or `-1` when the module has no static fields.
  final int staticInit;

  /// The entry-point function, or `null` if this module has no entry point.
  FunctionProto? get entry =>
      entryFunction == -1 ? null : functions[entryFunction];
}
