// Copyright (c) Ejenix authors. MIT license.

// `Label` collides with the bytecode assembler's Label; we use the latter.
import 'package:analyzer/dart/ast/ast.dart' hide Label;
// The AST `Label` node collides with the bytecode assembler's `Label`, which is
// used pervasively here; import just the AST one under a prefix.
import 'package:analyzer/dart/ast/ast.dart' as ast show Label;
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:ejenix_bytecode/bytecode.dart';

import 'capture.dart';
import 'diagnostic.dart';

/// Thrown internally to abandon compilation of the current function after an
/// unsupported construct has been recorded as a diagnostic. Caught by the
/// orchestrator, which has already collected the error.
class AbortCompilation implements Exception {
  const AbortCompilation();
}

/// A growable, index-addressed sink for function prototypes shared across every
/// [FunctionCompiler] in a compilation. Top-level functions, methods, and
/// constructors reserve their slots up front; nested closures reserve fresh
/// slots on demand while their enclosing function is being lowered, then place
/// their compiled proto. This lets a closure receive a stable module function
/// index even though it is discovered mid-compilation.
class ProtoSink {
  final List<FunctionProto?> _slots = [];

  /// Reserves the next function index, returning it. The slot holds `null`
  /// until [place]d.
  int reserve() {
    _slots.add(null);
    return _slots.length - 1;
  }

  /// Stores the compiled [proto] at a previously [reserve]d [index].
  void place(int index, FunctionProto proto) => _slots[index] = proto;

  /// The finalized, gap-free proto list. Throws [StateError] if any reserved
  /// slot was never placed (an internal compiler invariant violation).
  List<FunctionProto> build() => [
    for (final p in _slots)
      p ?? (throw StateError('unplaced function slot in module')),
  ];
}

/// The break/continue targets of an enclosing loop (or a labeled statement,
/// which only supports `break`).
class LoopContext {
  LoopContext(
    this.continueLabel,
    this.breakLabel,
    this.finallyDepth, {
    this.labels = const [],
    this.breakOnly = false,
  });
  final Label continueLabel;
  final Label breakLabel;

  /// The `_finallys` stack depth when this loop was entered. A `break` or
  /// `continue` targeting this loop must run every `finally` pushed after this
  /// point before jumping.
  final int finallyDepth;

  /// The source labels naming this loop, so `break`/`continue label` can target
  /// an outer loop rather than the innermost one.
  final List<String> labels;

  /// Whether this context is a labeled non-loop (only `break` is valid).
  final bool breakOnly;
}

/// A pending `finally` block. [emit] compiles a fresh copy of the block inline;
/// it is invoked on normal completion, on the exceptional path, and before any
/// `return`/`break`/`continue` that exits the protected region.
class _FinallyContext {
  _FinallyContext(this.emit);
  final void Function() emit;
}

/// The compiled shape of a class: where its instances live in the module's
/// class table, which function is its constructor, and the slot of each field
/// (including inherited fields) by name.
class ClassLayout {
  ClassLayout({
    required this.classIndex,
    required this.constructorIndex,
    required this.fieldsByName,
    required this.classElement,
    this.constructors = const {},
    this.factories = const {},
  });

  final int classIndex;

  /// The unnamed generative constructor's function index (used for an implicit
  /// `super()` and as `constructors['']`).
  final int constructorIndex;
  final Map<String, int> fieldsByName;
  final Element classElement;

  /// Every constructor's function index keyed by name (`''` for the unnamed
  /// one). Generative constructors take `this`; factory ones are plain functions.
  final Map<String, int> constructors;

  /// Names of the constructors that are factories (a plain function returning an
  /// instance, dispatched without `alloc`).
  final Set<String> factories;
}

/// Lowers one resolved [FunctionDeclaration] to a [FunctionProto].
///
/// The allocator is a single bump cursor over the register file: parameters
/// take the lowest registers, locals are reserved as they are declared within
/// their block scope, and expression temporaries are allocated above the live
/// locals and freed back at each statement boundary (the standard scheme for an
/// AST-walking register compiler, as in Lua's). Static types from the analyzer
/// drive typed-opcode selection (`add.i` vs `add.d`), with `i2d` widening
/// inserted for mixed-numeric operands and the `/` operator.
///
/// One instance compiles exactly one function.
class FunctionCompiler {
  FunctionCompiler({
    required ConstantPool constants,
    required Map<Element, int> functionIndices,
    required List<CallSite> callSites,
    required String path,
    required LineInfo lineInfo,
    required List<CompileDiagnostic> diagnostics,
    required ProtoSink sink,
    Map<Element, ClassLayout> classLayouts = const {},
    ClassLayout? enclosingClass,
    Map<Element, int> upvalues = const {},
    int thisUpvalue = -1,
    Map<Element, EnumValue> enumValues = const {},
    Map<Element, List<EnumValue>> enumMembers = const {},
    Map<Element, int> staticFields = const {},
    Map<Element, int> methodIndices = const {},
    Map<Element, String> extensionTypes = const {},
    String? extensionRepName,
    bool isExtension = false,
  }) : _constants = constants,
       _staticFields = staticFields,
       _methodIndices = methodIndices,
       _extensionTypes = extensionTypes,
       _extensionRepName = extensionRepName,
       _isExtension = isExtension,
       _functionIndices = functionIndices,
       _callSites = callSites,
       _path = path,
       _lineInfo = lineInfo,
       _diagnostics = diagnostics,
       _sink = sink,
       _classLayouts = classLayouts,
       _enclosingClass = enclosingClass,
       _upvalues = upvalues,
       _thisUpvalue = thisUpvalue,
       _enumValues = enumValues,
       _enumMembers = enumMembers;

  final ConstantPool _constants;
  final Map<Element, int> _functionIndices;
  final List<CallSite> _callSites;
  final String _path;
  final LineInfo _lineInfo;
  final List<CompileDiagnostic> _diagnostics;

  /// The module-wide function-proto sink, used to reserve and place indices for
  /// closures discovered while lowering this function's body.
  final ProtoSink _sink;

  /// Class shapes, keyed by class element, for instance creation and typed
  /// field access.
  final Map<Element, ClassLayout> _classLayouts;

  /// The class whose method/constructor is being compiled, if any. When set,
  /// `this` is register 0 and unqualified fields resolve against it.
  final ClassLayout? _enclosingClass;

  /// Whether the function being compiled is an extension member. `this`
  /// (register 0) is the extended receiver, but there is no class layout, so
  /// unqualified members and `this.member` dispatch dynamically on the receiver.
  final bool _isExtension;

  /// Static fields, keyed by element, mapped to their module global index.
  final Map<Element, int> _staticFields;

  /// Instance methods, keyed by element, mapped to their function index — used
  /// to statically dispatch an explicit `super.method(...)`.
  final Map<Element, int> _methodIndices;

  /// Extension-type elements mapped to their representation field name.
  /// Construction and representation access on these lower to identity.
  final Map<Element, String> _extensionTypes;

  /// When compiling an extension-type member, its representation field name, so
  /// an unqualified reference to it resolves to `this` (the erased value).
  final String? _extensionRepName;

  /// When compiling a closure body: the captured enclosing variables, mapped to
  /// their upvalue index. At the prologue each is loaded from the closure's
  /// upvalue slot into a register that then behaves like a boxed local.
  final Map<Element, int> _upvalues;

  /// When compiling a closure that captured `this`: the upvalue index of the
  /// captured `this` cell, else `-1`. Loaded into [_thisReg] at the prologue.
  final int _thisUpvalue;

  /// Enum constant elements to their interned [EnumValue], so `Color.red` is a
  /// single `load.const`.
  final Map<Element, EnumValue> _enumValues;

  /// Enum type elements to their ordered value list, for `Color.values`.
  final Map<Element, List<EnumValue>> _enumMembers;

  /// The register holding a capturable `Cell(this)` in a method/constructor that
  /// has a `this`-capturing nested closure, else `-1`.
  int _thisCellReg = -1;

  /// This function's own locals/parameters that a nested closure captures, and
  /// so must be boxed into cells at declaration.
  Set<Element> _captured = const {};

  /// Elements whose register currently holds a [Cell] rather than a bare value:
  /// captured locals/parameters and loaded upvalues. Access to these goes
  /// through `cell.get` / `cell.set`.
  final Set<Element> _boxed = {};

  /// The parent registers this proto captures, in upvalue order — non-empty
  /// only for a closure. Passed through to the emitted [FunctionProto].
  List<int> _captures = const [];

  /// Whether the function being compiled is `async` (returns a `Future`, may
  /// `await`). Set from the body's modifier before lowering.
  bool _isAsync = false;

  /// Generator state. A `sync*`/`async*` function is lowered *eagerly*: its
  /// Generator kind. A `sync*`/`async*` function compiles its body normally,
  /// emitting a `yield` opcode per `yield`; the runtime returns a lazy sequence
  /// that drives the body one element at a time (so infinite generators work).
  bool _isSyncStar = false;
  bool _isAsyncStar = false;

  bool get _isGenerator => _isSyncStar || _isAsyncStar;

  /// The register holding `this` inside a method or constructor (register 0),
  /// or the register materialized from a captured `this` cell inside a closure.
  int _thisReg = 0;

  /// Interns a dynamic-dispatch call site, returning its index. Each syntactic
  /// call gets its own site so its inline cache is not polluted by others.
  int _callSite(String selector, int argCount) {
    _callSites.add(CallSite(selector: selector, argCount: argCount));
    return _callSites.length - 1;
  }

  /// Emits `dest = receiverReg.selector(argRegs...)` via dynamic dispatch,
  /// copying the receiver and arguments into a fresh contiguous block so live
  /// variables in [receiverReg]/[argRegs] are never clobbered by the void
  /// results of setters or mutators. A `null` [dest] discards the result.
  void _emitInvoke(
    int? dest,
    int receiverReg,
    String selector,
    List<int> argRegs,
  ) {
    final mark = _top;
    final base = _alloc();
    _b.emitAB(Op.move, base, receiverReg);
    for (final arg in argRegs) {
      _b.emitAB(Op.move, _alloc(), arg);
    }
    _b.emitABx(Op.invokeDyn, base, _callSite(selector, argRegs.length));
    if (dest != null && dest != base) _b.emitAB(Op.move, dest, base);
    _top = mark;
  }

  final BytecodeBuilder _b = BytecodeBuilder();
  final Map<Element, int> _locals = {};
  final List<LoopContext> _loops = [];

  /// The stack of enclosing `finally` blocks, innermost last. Non-empty only
  /// inside a `try` that has a `finally`; drives finally-on-exit lowering.
  final List<_FinallyContext> _finallys = [];

  /// The catch registers of enclosing `catch` clauses, innermost last. `rethrow`
  /// re-raises the value in the innermost one.
  final List<int> _catchRegs = [];

  /// Labels from an enclosing [LabeledStatement] waiting to be attached to the
  /// loop they immediately precede. Consumed (and cleared) by [_pushLoop].
  List<String> _pendingLabels = const [];

  /// Pushes a loop context, attaching any [_pendingLabels] so `break`/`continue
  /// label` can target it, and clears the pending labels.
  void _pushLoop(Label continueLabel, Label breakLabel) {
    _loops.add(
      LoopContext(
        continueLabel,
        breakLabel,
        _finallys.length,
        labels: _pendingLabels,
      ),
    );
    _pendingLabels = const [];
  }

  /// Resolves the loop/labeled context a `break`/`continue` targets: the label's
  /// context if named, else the innermost enclosing loop.
  LoopContext _resolveLoopTarget(LabelReference? label, AstNode node) {
    if (label == null) {
      if (_loops.isEmpty) _unsupported(node, 'break/continue outside a loop');
      return _loops.last;
    }
    final name = label.name.lexeme;
    for (var i = _loops.length - 1; i >= 0; i--) {
      if (_loops[i].labels.contains(name)) return _loops[i];
    }
    _unsupported(node, 'no enclosing statement labeled `$name`');
  }

  /// Registers currently reserved (params + live locals + live temporaries).
  int _top = 0;

  /// High-water mark of [_top]; the function's register count.
  int _max = 0;

  /// Elements declared in the current block scope, popped on block exit.
  List<Element> _scope = [];

  int _alloc() {
    final r = _top++;
    if (_top > _max) _max = _top;
    return r;
  }

  /// Compiles a top-level function [decl] and returns its prototype.
  FunctionProto compile(FunctionDeclaration decl) {
    final expr = decl.functionExpression;
    final params = expr.parameters?.parameters ?? const <FormalParameter>[];
    _markAsync(expr.body);
    _captured = capturedVariables(expr.body);
    _bindParams(params);
    _compileBody(expr.body);
    return _finishProto(decl.name.lexeme, params.length, decl);
  }

  /// Compiles an instance method [decl]; `this` occupies register 0.
  FunctionProto compileMethod(MethodDeclaration decl) {
    _alloc(); // R[0] = this
    final params = decl.parameters?.parameters ?? const <FormalParameter>[];
    _markAsync(decl.body);
    _captured = capturedVariables(decl.body);
    _bindParams(params);
    if (anyNestedClosureCapturesThis(decl.body)) _materializeThisCell();
    _compileBody(decl.body);
    return _finishProto(decl.name.lexeme, 1 + params.length, decl);
  }

  /// The global index for a static field referenced by [element], resolving a
  /// getter/setter back to its field (a read/write resolves to the accessor,
  /// while the field itself is what the map is keyed by). `null` if not static.
  int? _staticGlobalFor(Element? element) {
    if (element == null) return null;
    final field = element is PropertyAccessorElement
        ? element.variable
        : element;
    return _staticFields[field];
  }

  /// Compiles an assignment whose target is a static field (a module global):
  /// `=`, `??=`, and compound operators, evaluating to the stored value.
  void _compileStaticFieldAssign(
    AssignmentExpression e,
    int globalIndex,
    int? dest,
  ) {
    final opType = e.operator.type;
    final mark = _top;
    final valueReg = _alloc();
    if (opType == TokenType.EQ) {
      _compileExprInto(e.rightHandSide, valueReg);
    } else if (opType == TokenType.QUESTION_QUESTION_EQ) {
      _b.emitABx(Op.loadGlobal, valueReg, globalIndex);
      final nullReg = _alloc();
      _b.emitA(Op.loadNull, nullReg);
      final cond = _alloc();
      _b.emitABC(Op.ne, cond, valueReg, nullReg);
      final end = _b.newLabel();
      _b.emitBranch(Op.jnz, cond, end); // already non-null: keep it
      _compileExprInto(e.rightHandSide, valueReg);
      _b.bind(end);
    } else {
      final current = _alloc();
      _b.emitABx(Op.loadGlobal, current, globalIndex);
      final rhs = _compileOperand(e.rightHandSide);
      _emitBinaryOp(
        _compoundOperator(e),
        valueReg,
        current,
        rhs,
        e.leftHandSide.staticType,
        e.rightHandSide.staticType,
        e,
      );
    }
    _b.emitABx(Op.storeGlobal, valueReg, globalIndex);
    if (dest != null && dest != valueReg) _b.emitAB(Op.move, dest, valueReg);
    _top = mark;
  }

  /// Compiles the module's static initializer: evaluates each static field's
  /// initializer and stores it into that field's global slot, once, before the
  /// entry point runs.
  FunctionProto compileStaticInit(List<(int, Expression)> inits) {
    for (final (globalIndex, expr) in inits) {
      final mark = _top;
      final value = _alloc();
      _compileExprInto(expr, value);
      _b.emitABx(Op.storeGlobal, value, globalIndex);
      _top = mark;
    }
    _b.emitNone(Op.retVoid);
    return _finishProto('<clinit>', 0);
  }

  /// Compiles a `static` method [decl] as a plain function — no receiver, so
  /// parameters occupy the lowest registers, exactly like a top-level function.
  FunctionProto compileStaticMethod(MethodDeclaration decl) {
    final params = decl.parameters?.parameters ?? const <FormalParameter>[];
    _markAsync(decl.body);
    _captured = capturedVariables(decl.body);
    _bindParams(params);
    _compileBody(decl.body);
    return _finishProto(decl.name.lexeme, params.length, decl);
  }

  /// Compiles an extension member [decl] (method or getter). Register 0 is the
  /// extended receiver (`this`); the member is invoked statically with the
  /// receiver as its first argument. Member access inside the body dispatches
  /// dynamically on the receiver, since an extension has no field layout.
  FunctionProto compileExtensionMember(MethodDeclaration decl) {
    _alloc(); // R[0] = the extended receiver
    final params = decl.parameters?.parameters ?? const <FormalParameter>[];
    _markAsync(decl.body);
    _captured = capturedVariables(decl.body);
    _bindParams(params);
    _compileBody(decl.body);
    return _finishProto('ext\$${decl.name.lexeme}', 1 + params.length, decl);
  }

  /// Boxes a copy of `this` into a cell so a nested closure can capture the
  /// receiver by reference (`this` is never reassigned, so the copy is faithful).
  /// The method keeps using [_thisReg] (register 0) directly for its own field
  /// access; only closures read through the cell.
  void _materializeThisCell() {
    _thisCellReg = _alloc();
    _b.emitAB(Op.move, _thisCellReg, _thisReg);
    _b.emitA(Op.cellNew, _thisCellReg);
  }

  /// Records the body's `async`/generator modifiers. `async*` runs on the event
  /// loop like `async` (it may `await`); both generator kinds collect their
  /// yields eagerly (see [_yieldListReg]).
  void _markAsync(FunctionBody body) {
    final generator = body.isGenerator;
    _isSyncStar = generator && !body.isAsynchronous;
    _isAsyncStar = generator && body.isAsynchronous;
    // Only a plain `async` function drives the event loop; a generator's body
    // runs lazily as its sequence is pulled. `await` inside a generator is
    // rejected at the `await` site.
    _isAsync = body.isAsynchronous && !generator;
  }

  /// Compiles an anonymous function or local function [fe] to a closure proto.
  /// [captures] are the enclosing registers (holding cells) this closure grabs,
  /// in upvalue order; they are recorded on the proto so `closure.new` needs
  /// only the proto index. The matching `_upvalues` map (element to index) was
  /// supplied to the constructor; each upvalue is loaded into a register here.
  FunctionProto compileClosure(FunctionExpression fe, List<int> captures) {
    _captures = captures;
    final params = fe.parameters?.parameters ?? const <FormalParameter>[];
    _markAsync(fe.body);
    _captured = capturedVariables(fe.body);
    _bindParams(params);
    // Load each captured upvalue cell into a register, in upvalue-index order,
    // and treat it as a boxed local for the rest of the body.
    final ordered = _upvalues.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in ordered) {
      final reg = _alloc();
      _b.emitABx(Op.upvalGet, reg, entry.value);
      _locals[entry.key] = reg;
      _boxed.add(entry.key);
    }
    // If this closure captured `this`, load it from its upvalue cell into a
    // register that field access and method dispatch then use as the receiver.
    if (_thisUpvalue >= 0) {
      final cellReg = _alloc();
      _b.emitABx(Op.upvalGet, cellReg, _thisUpvalue);
      _thisReg = _alloc();
      _b.emitAB(Op.cellGet, _thisReg, cellReg);
      // Re-box `this` if a further-nested closure captures it too (e.g.
      // `setState(() => field++)` inside an `onPressed`).
      if (anyNestedClosureCapturesThis(fe.body)) _materializeThisCell();
    }
    _compileBody(fe.body);
    return _finishProto('<closure>', params.length);
  }

  /// Compiles a factory constructor as a plain function: it takes no receiver
  /// and its body returns the constructed instance. A redirecting factory
  /// (`factory C(…) = D`) forwards its parameters to the target constructor.
  FunctionProto compileFactory(ConstructorDeclaration decl) {
    final params = decl.parameters.parameters;
    _markAsync(decl.body);
    _captured = capturedVariables(decl.body);
    _bindParams(params);
    final redirect = decl.redirectedConstructor;
    if (redirect != null) {
      _compileRedirectingFactory(redirect, params);
    } else {
      _compileBody(decl.body);
    }
    return _finishProto('${decl.name?.lexeme ?? ''}\$factory', params.length);
  }

  /// Emits `return <target>(params…)` for a redirecting factory, forwarding the
  /// factory's parameters positionally to the [redirect] target's constructor.
  void _compileRedirectingFactory(
    ConstructorName redirect,
    List<FormalParameter> params,
  ) {
    final targetClass = redirect.type.element;
    final layout = targetClass == null ? null : _classLayouts[targetClass];
    if (layout == null) {
      _unsupported(
        redirect,
        'a redirecting factory must target a class declared in this unit',
      );
    }
    final ctorName = redirect.name?.name ?? '';
    final ctorIndex = layout.constructors[ctorName];
    if (ctorIndex == null) {
      _unsupported(
        redirect,
        'redirecting factory target constructor not found',
      );
    }
    final argRegs = [
      for (final p in params) _locals[p.declaredFragment?.element]!,
    ];
    final mark = _top;
    final resultReg = _alloc();
    if (layout.factories.contains(ctorName)) {
      final callBase = _alloc();
      for (var i = 0; i < argRegs.length; i++) {
        final slot = _alloc();
        _b.emitAB(Op.move, slot, argRegs[i]);
      }
      _b
        ..emitABx(Op.loadFunc, callBase, ctorIndex)
        ..emitABC(Op.call, callBase, 0, argRegs.length)
        ..emitAB(Op.move, resultReg, callBase);
    } else {
      _b.emitABx(Op.alloc, resultReg, layout.classIndex);
      final callBase = _alloc();
      _alloc(); // callBase+1 = this
      _b
        ..emitABx(Op.loadFunc, callBase, ctorIndex)
        ..emitAB(Op.move, callBase + 1, resultReg);
      for (var i = 0; i < argRegs.length; i++) {
        final slot = _alloc();
        _b.emitAB(Op.move, slot, argRegs[i]);
      }
      _b.emitABC(Op.call, callBase, 0, argRegs.length + 1);
    }
    _b.emitA(Op.ret, resultReg);
    _top = mark;
  }

  /// Compiles a generative constructor [decl] (or the default constructor when
  /// null); `this` occupies register 0. [fieldInitializers] are the
  /// declaration-site field initializers (`int x = 0`), applied before
  /// field-formals and the body.
  FunctionProto compileConstructor(
    ConstructorDeclaration? decl,
    String name,
    List<(int, Expression)> fieldInitializers,
    int superConstructorIndex,
  ) {
    _alloc(); // R[0] = this
    final params = decl?.parameters.parameters ?? const <FormalParameter>[];
    final layout = _enclosingClass!;

    // Bind parameters (so the initializer list can reference them), recording
    // field-formal stores. Optional/named params and defaults are supported.
    // All slots are reserved before any default fill so a fill's scratch
    // register cannot clobber a later parameter's incoming argument.
    final formalInits = <(int, int)>[]; // (slot, paramReg)
    final boundParams = <(int, FormalParameter)>[]; // (reg, param)
    final superFormals = <String, int>{}; // super-formal name -> reg
    for (final p in params) {
      final reg = _alloc();
      final element = p.declaredFragment?.element;
      if (element != null) _locals[element] = reg;
      boundParams.add((reg, p));
      if (p is FieldFormalParameter) {
        final slot = layout.fieldsByName[p.name.lexeme];
        if (slot == null) {
          _unsupported(
            p,
            'field-formal `this.${p.name.lexeme}` names no field',
          );
        }
        formalInits.add((slot, reg));
      } else if (p is SuperFormalParameter) {
        // `super.x`: bind the value and forward it to the super constructor.
        superFormals[p.name.lexeme] = reg;
      } else if (p is! RegularFormalParameter) {
        _unsupported(p, 'this parameter form is not yet supported');
      }
    }
    for (final (reg, p) in boundParams) {
      if (p.isOptional) _fillDefault(reg, p.defaultClause?.value);
    }

    // A redirecting generative constructor `C.x() : this(...)` delegates fully
    // to another of this class's constructors; it runs no field init or super.
    for (final init in decl?.initializers ?? const <ConstructorInitializer>[]) {
      if (init is RedirectingConstructorInvocation) {
        final targetName = init.constructorName?.name ?? '';
        final targetIndex = layout.constructors[targetName];
        if (targetIndex == null) {
          _unsupported(init, 'redirecting constructor target not found');
        }
        _emitCtorDelegation(
          targetIndex,
          init.argumentList.arguments,
          init.element?.formalParameters ?? const <FormalParameterElement>[],
          const {},
        );
        _b.emitNone(Op.retVoid);
        return _finishProto(name, 1 + params.length);
      }
    }

    final ctorBody = decl?.body;
    if (ctorBody != null && anyNestedClosureCapturesThis(ctorBody)) {
      _materializeThisCell();
    }

    // Declaration-site initializers and field-formals.
    for (final (slot, expr) in fieldInitializers) {
      final mark = _top;
      final value = _compileOperand(expr);
      _b.emitABC(Op.storeField, _thisReg, slot, value);
      _top = mark;
    }
    for (final (slot, reg) in formalInits) {
      _b.emitABC(Op.storeField, _thisReg, slot, reg);
    }

    // Constructor initializer list: `: field = expr` and `: super(args)`.
    SuperConstructorInvocation? superCall;
    for (final init in decl?.initializers ?? const <ConstructorInitializer>[]) {
      switch (init) {
        case ConstructorFieldInitializer():
          final slot = layout.fieldsByName[init.fieldName.name];
          if (slot == null) {
            _unsupported(init, 'initializer names no field');
          }
          final mark = _top;
          final value = _compileOperand(init.expression);
          _b.emitABC(Op.storeField, _thisReg, slot, value);
          _top = mark;
        case SuperConstructorInvocation():
          superCall = init;
        default:
          _unsupported(init, 'this constructor initializer is not supported');
      }
    }

    // Chain to the superclass constructor (explicit `super(...)` or implicit),
    // forwarding any `super.x` formal parameters.
    if (superConstructorIndex >= 0) {
      final superParams =
          decl?.declaredFragment?.element.superConstructor?.formalParameters ??
          const <FormalParameterElement>[];
      _emitCtorDelegation(
        superConstructorIndex,
        superCall?.argumentList.arguments ?? const <Argument>[],
        superParams,
        superFormals,
      );
    }

    final body = decl?.body;
    if (body is BlockFunctionBody) {
      _compileBlock(body.block);
    } else if (body != null && body is! EmptyFunctionBody) {
      _unsupported(body, 'this constructor body form is not yet supported');
    }
    _b.emitNone(Op.retVoid);
    return _finishProto(name, 1 + params.length);
  }

  /// Emits a delegating constructor call on `this` — a `super(...)` chain or a
  /// `this(...)` redirect. Each target parameter is filled from a matching
  /// `super.x` formal ([superFormals], by name) if present, else from [args]
  /// (by name/position), else the absent-argument sentinel.
  void _emitCtorDelegation(
    int constructorIndex,
    List<Argument> args,
    List<FormalParameterElement> params,
    Map<String, int> superFormals,
  ) {
    final byName = <String, Expression>{};
    final positional = <Expression>[];
    for (final arg in args) {
      if (arg is NamedArgument) {
        byName[_namedArgLabel(arg)] = arg.argumentExpression;
      } else {
        positional.add(arg.argumentExpression);
      }
    }
    final mark = _top;
    final callBase = _alloc();
    _b.emitABx(Op.loadFunc, callBase, constructorIndex);
    _alloc(); // callBase+1 = this
    _b.emitAB(Op.move, callBase + 1, _thisReg);
    for (var i = 0; i < params.length; i++) {
      _alloc(); // callBase + 2 + i
    }
    var posIdx = 0;
    for (var i = 0; i < params.length; i++) {
      final p = params[i];
      final slot = callBase + 2 + i;
      final forwarded = superFormals[p.name];
      if (forwarded != null) {
        _b.emitAB(Op.move, slot, forwarded);
        continue;
      }
      final expr = p.isNamed
          ? byName[p.name]
          : (posIdx < positional.length ? positional[posIdx++] : null);
      if (expr != null) {
        _compileExprInto(expr, slot);
      } else {
        _b.emitA(Op.loadUndef, slot);
      }
    }
    _b.emitABC(Op.call, callBase, 0, params.length + 1);
    _top = mark;
  }

  void _bindParams(List<FormalParameter> params) {
    // Reserve every parameter slot first, so the scratch registers a default
    // fill uses sit *above* the whole parameter block and cannot clobber a
    // later parameter's incoming argument.
    final bound = <(Element, int, FormalParameter)>[];
    for (final p in params) {
      if (p is! RegularFormalParameter) {
        _unsupported(p, 'this parameter form is not yet supported');
      }
      final element = p.declaredFragment?.element;
      if (element == null) {
        _unsupported(p, 'parameter has no resolved element');
      }
      final reg = _alloc();
      _locals[element] = reg;
      bound.add((element, reg, p));
    }
    // Optional (positional or named) parameters may be absent at the call site;
    // the caller passes the sentinel and we substitute the default here.
    for (final (_, reg, p) in bound) {
      if (p.isOptional) _fillDefault(reg, p.defaultClause?.value);
    }
    for (final (element, reg, _) in bound) {
      _maybeBox(element, reg);
    }
  }

  /// Emits a callee-prologue fill for an optional parameter in [slot]: if the
  /// caller omitted it (the slot holds the absent sentinel), assign
  /// [defaultValue] — or `null` when there is no explicit default.
  void _fillDefault(int slot, Expression? defaultValue) {
    final mark = _top;
    final undef = _alloc();
    _b.emitA(Op.loadUndef, undef);
    final cond = _alloc();
    _b.emitABC(Op.eq, cond, slot, undef); // cond = (slot == absent)
    final provided = _b.newLabel();
    _b.emitBranch(Op.jz, cond, provided); // slot provided: keep it
    if (defaultValue != null) {
      _compileExprInto(defaultValue, slot);
    } else {
      _b.emitA(Op.loadNull, slot);
    }
    _b.bind(provided);
    _top = mark;
  }

  /// Boxes [element]'s register into a cell if a nested closure captures it, so
  /// reads/writes become `cell.get`/`cell.set` and the closure shares the same
  /// mutable location. The value to box must already be in [reg].
  void _maybeBox(Element element, int reg) {
    if (_captured.contains(element)) {
      _b.emitA(Op.cellNew, reg);
      _boxed.add(element);
    }
  }

  void _compileBody(FunctionBody body) {
    // A generator body runs normally; `yield` emits the yield opcode and the
    // trailing `ret.void` signals completion to the driver.
    if (_isGenerator) {
      if (body is BlockFunctionBody) {
        _compileBlock(body.block);
      } else {
        _unsupported(body, 'a generator must have a block body');
      }
      _b.emitNone(Op.retVoid);
      return;
    }
    switch (body) {
      case BlockFunctionBody():
        _compileBlock(body.block);
        _b.emitNone(Op.retVoid);
      case ExpressionFunctionBody():
        final mark = _top;
        final r = _compileOperand(body.expression);
        _b.emitA(Op.ret, r);
        _top = mark;
      default:
        _unsupported(body, 'this function body form is not supported');
    }
  }

  FunctionProto _finishProto(String name, int paramCount, [AstNode? at]) {
    // A register index is one byte, so 255 is a hard encoding limit. This used
    // to `.clamp(1, 255)`: a function needing more was silently truncated, the
    // encoder's range checks were `assert`s (stripped in release), and the
    // result was a signed, published bundle whose registers aliased each other.
    // Silent miscompilation is the worst outcome available here — fail the
    // build instead.
    final needed = _max < paramCount ? paramCount : _max;
    if (needed > 255) {
      _registerOverflow(name, needed, at);
    }
    final registerCount = needed < 1 ? 1 : needed;
    return _b.toProto(
      name: name,
      paramCount: paramCount,
      registerCount: registerCount,
      captures: _captures,
      isAsync: _isAsync,
      isSyncStar: _isSyncStar,
      isAsyncStar: _isAsyncStar,
    );
  }

  // --- Statements ---

  void _compileStatement(Statement s) {
    switch (s) {
      case Block():
        _compileBlock(s);
      case VariableDeclarationStatement():
        _compileVariableDeclarationList(s.variables);
      case PatternVariableDeclarationStatement():
        _compilePatternDeclaration(s.declaration);
      case ExpressionStatement():
        final mark = _top;
        _compileExpressionForEffect(s.expression);
        _top = mark;
      case IfStatement():
        _compileIf(s);
      case WhileStatement():
        _compileWhile(s);
      case DoStatement():
        _compileDoWhile(s);
      case SwitchStatement():
        _compileSwitchStatement(s);
      case ForStatement():
        _compileFor(s);
      case TryStatement():
        _compileTry(s);
      case ReturnStatement():
        _compileReturn(s);
      case LabeledStatement():
        _compileLabeledStatement(s);
      case BreakStatement():
        final target = _resolveLoopTarget(s.label, s);
        _runPendingFinallys(target.finallyDepth);
        _b.emitJmp(target.breakLabel);
      case ContinueStatement():
        final target = _resolveLoopTarget(s.label, s);
        if (target.breakOnly) {
          _unsupported(s, '`continue` cannot target a non-loop label');
        }
        _runPendingFinallys(target.finallyDepth);
        _b.emitJmp(target.continueLabel);
      case EmptyStatement():
        break;
      case YieldStatement():
        if (s.star != null) {
          _compileYieldStar(s.expression);
        } else {
          final mark = _top;
          final v = _compileOperand(s.expression);
          _b.emitA(Op.yieldValue, v);
          _top = mark;
        }
      case AssertStatement():
        _compileAssert(s);
      case FunctionDeclarationStatement():
        _compileLocalFunction(s.functionDeclaration);
      default:
        _unsupported(s, 'statement `${astKindName(s)}` is not yet supported');
    }
  }

  /// Lowers `yield* iterable` to a loop that yields each element in turn,
  /// reusing the single-`yield` opcode and the Iterator protocol.
  void _compileYieldStar(Expression iterable) {
    final mark = _top;
    final src = _compileOperand(iterable);
    final iterReg = _alloc();
    _emitInvoke(iterReg, src, 'iterator', const []);
    final bodyMark = _top;
    final loop = _b.newLabel();
    final end = _b.newLabel();
    _b.bind(loop);
    final hasNext = _alloc();
    _emitInvoke(hasNext, iterReg, 'moveNext', const []);
    _b.emitBranch(Op.jz, hasNext, end);
    _top = bodyMark;
    final cur = _alloc();
    _emitInvoke(cur, iterReg, 'current', const []);
    _b.emitA(Op.yieldValue, cur);
    _top = bodyMark;
    _b.emitJmp(loop);
    _b.bind(end);
    _top = mark;
  }

  /// Compiles a labeled statement. When it labels a loop, the labels ride into
  /// that loop's context (via [_pendingLabels]) so `break`/`continue label` can
  /// target it. When it labels any other statement, a break-only context whose
  /// target is the end of the statement lets `break label` jump past it.
  void _compileLabeledStatement(LabeledStatement s) {
    final names = [for (final ast.Label label in s.labels) label.name.lexeme];
    final inner = s.statement;
    final isLoop =
        inner is WhileStatement ||
        inner is DoStatement ||
        inner is ForStatement ||
        inner is SwitchStatement;
    if (isLoop) {
      final saved = _pendingLabels;
      _pendingLabels = [...saved, ...names];
      _compileStatement(inner);
      _pendingLabels = saved;
    } else {
      final end = _b.newLabel();
      _loops.add(
        LoopContext(end, end, _finallys.length, labels: names, breakOnly: true),
      );
      _compileStatement(inner);
      _loops.removeLast();
      _b.bind(end);
    }
  }

  /// Lowers `assert(cond)` / `assert(cond, msg)` to a guarded throw: when the
  /// condition is false, build an `AssertionError` (with the optional message)
  /// and throw it. A statically-true constant condition compiles to nothing.
  void _compileAssert(AssertStatement s) {
    final constCond = _constFold(s.condition);
    if (constCond == true) return; // provably holds — emit nothing
    final mark = _top;
    final cond = _compileOperand(s.condition);
    final ok = _b.newLabel();
    if (constCond != false) {
      _b.emitBranch(Op.jnz, cond, ok); // condition true -> skip the throw
    }
    _top = mark;
    // Build AssertionError({message: …}) via the host allow-list, then throw.
    final mapReg = _alloc();
    _b.emitA(Op.mapNew, mapReg);
    final message = s.message;
    if (message != null) {
      final inner = _top;
      final keyReg = _alloc();
      _loadConstValue(keyReg, 'message');
      final valReg = _alloc();
      _compileExprInto(message, valReg);
      _emitInvoke(null, mapReg, '[]=', [keyReg, valReg]);
      _top = inner;
    }
    _b.emitABx(Op.invokeStatic, mapReg, _callSite('AssertionError', 1));
    _b.emitA(Op.throwValue, mapReg);
    _top = mark;
    _b.bind(ok);
  }

  /// Compiles a local (named) function declaration, e.g. `int f(int x) => …;`.
  /// It is bound through a cell so it can capture itself for recursion and be
  /// captured by sibling closures uniformly.
  void _compileLocalFunction(FunctionDeclaration decl) {
    final element = decl.declaredFragment?.element;
    if (element == null) {
      _unsupported(decl, 'local function has no resolved element');
    }
    final reg = _alloc();
    _locals[element] = reg;
    _scope.add(element);
    _b.emitA(Op.loadNull, reg);
    _b.emitA(Op.cellNew, reg);
    _boxed.add(element);
    final mark = _top;
    final tmp = _alloc();
    _compileFunctionExpressionInto(decl.functionExpression, tmp);
    _b.emitAB(Op.cellSet, reg, tmp);
    _top = mark;
  }

  void _compileBlock(Block block) {
    final savedTop = _top;
    final savedScope = _scope;
    _scope = [];
    for (final statement in block.statements) {
      _compileStatement(statement);
    }
    for (final element in _scope) {
      _locals.remove(element);
    }
    _scope = savedScope;
    _top = savedTop;
  }

  void _compileVariableDeclarationList(VariableDeclarationList list) {
    for (final variable in list.variables) {
      final element = variable.declaredFragment?.element;
      if (element == null) {
        _unsupported(variable, 'variable has no resolved element');
      }
      final reg = _alloc();
      _locals[element] = reg;
      _scope.add(element);
      final initializer = variable.initializer;
      if (initializer != null) {
        _compileExprInto(initializer, reg);
      } else {
        _b.emitA(Op.loadNull, reg);
      }
      _maybeBox(element, reg);
    }
  }

  void _compileIf(IfStatement s) {
    // `if (e case pattern when guard) …`: match, binding pattern variables for
    // the then-branch; a mismatch runs the else-branch.
    final caseClause = s.caseClause;
    if (caseClause != null) {
      _compileIfCase(s, caseClause);
      return;
    }

    // Dead-branch elimination: a constant condition emits only the taken branch,
    // so a guard like `if (kReleaseMode) …` costs nothing when it is const.
    final constCond = _constFold(s.expression);
    if (constCond is bool) {
      if (constCond) {
        _compileStatement(s.thenStatement);
      } else if (s.elseStatement != null) {
        _compileStatement(s.elseStatement!);
      }
      return;
    }

    final mark = _top;
    final cond = _compileOperand(s.expression);
    final elseLabel = _b.newLabel();
    _b.emitBranch(Op.jz, cond, elseLabel);
    _top = mark;
    _compileStatement(s.thenStatement);
    final elseStatement = s.elseStatement;
    if (elseStatement != null) {
      final endLabel = _b.newLabel();
      _b.emitJmp(endLabel);
      _b.bind(elseLabel);
      _compileStatement(elseStatement);
      _b.bind(endLabel);
    } else {
      _b.bind(elseLabel);
    }
  }

  /// Lowers `if (e case pattern [when guard]) then [else]`. The matched value's
  /// bindings are live in the then-branch only.
  void _compileIfCase(IfStatement s, CaseClause caseClause) {
    final mark = _top;
    final valueReg = _alloc();
    _compileExprInto(s.expression, valueReg);
    final elseLabel = _b.newLabel();
    final savedScope = _scope;
    final savedLocals = Map<Element, int>.of(_locals);
    _scope = [];
    _matchGuarded(caseClause.guardedPattern, valueReg, elseLabel);
    // then-branch: bindings from the match are in scope.
    _compileStatement(s.thenStatement);
    for (final el in _scope) {
      _locals.remove(el);
    }
    _locals
      ..clear()
      ..addAll(savedLocals);
    _scope = savedScope;
    final elseStatement = s.elseStatement;
    if (elseStatement != null) {
      final endLabel = _b.newLabel();
      _b.emitJmp(endLabel);
      _b.bind(elseLabel);
      _top = mark;
      _compileStatement(elseStatement);
      _b.bind(endLabel);
    } else {
      _b.bind(elseLabel);
    }
    _top = mark;
  }

  void _compileWhile(WhileStatement s) {
    // `while (false) …` never runs: emit nothing.
    if (_constFold(s.condition) == false) return;

    final condLabel = _b.newLabel();
    final endLabel = _b.newLabel();
    _b.bind(condLabel);
    final mark = _top;
    final cond = _compileOperand(s.condition);
    _b.emitBranch(Op.jz, cond, endLabel);
    _top = mark;
    _pushLoop(condLabel, endLabel);
    _compileStatement(s.body);
    _loops.removeLast();
    _b.emitJmp(condLabel);
    _b.bind(endLabel);
  }

  /// Lowers a `switch` statement to an equality-comparison chain: evaluate the
  /// scrutinee once, jump to the first matching constant case (or `default`),
  /// and run its body. Non-empty cases break implicitly; empty cases fall
  /// through to the next. Only constant `case` patterns are supported.
  void _compileSwitchStatement(SwitchStatement s) {
    final mark = _top;
    final scrutinee = _alloc();
    _compileExprInto(s.expression, scrutinee);
    final scrutineeMark = _top;
    final members = s.members;
    final end = _b.newLabel();
    final bodyLabels = [for (final _ in members) _b.newLabel()];
    int? defaultIndex;
    final caseBindings = [for (final _ in members) <Element, int>{}];
    final caseTops = List<int>.filled(members.length, scrutineeMark);

    // Pass 1: matching. Each case reuses the registers above the scrutinee (only
    // the matched case runs), and its bindings are recorded for pass 2.
    for (var i = 0; i < members.length; i++) {
      final m = members[i];
      if (m is SwitchDefault) {
        defaultIndex = i;
        continue;
      }
      _top = scrutineeMark;
      final savedLocals = Map<Element, int>.of(_locals);
      final savedScope = _scope;
      _scope = [];
      final next = _b.newLabel();
      if (m is SwitchPatternCase) {
        _matchGuarded(m.guardedPattern, scrutinee, next);
      } else if (m is SwitchCase) {
        final caseVal = _compileOperand(m.expression);
        final cond = _alloc();
        _b.emitABC(Op.eq, cond, scrutinee, caseVal);
        _b.emitBranch(Op.jz, cond, next);
      } else {
        _unsupported(m, 'this switch member form is not yet supported');
      }
      _b.emitJmp(bodyLabels[i]);
      _b.bind(next);
      for (final el in _scope) {
        caseBindings[i][el] = _locals[el]!;
      }
      caseTops[i] = _top;
      _locals
        ..clear()
        ..addAll(savedLocals);
      _scope = savedScope;
    }
    _b.emitJmp(defaultIndex != null ? bodyLabels[defaultIndex] : end);

    // Pass 2: bodies. Each installs its recorded bindings so member reads resolve
    // to the registers the match wrote. Empty cases fall through to the next.
    _pushLoop(end, end); // `break` exits the switch
    for (var i = 0; i < members.length; i++) {
      _b.bind(bodyLabels[i]);
      _top = caseTops[i];
      final bindings = caseBindings[i];
      final savedScope = _scope;
      _scope = bindings.keys.toList();
      _locals.addAll(bindings);
      for (final stmt in members[i].statements) {
        _compileStatement(stmt);
      }
      for (final el in bindings.keys) {
        _locals.remove(el);
      }
      _scope = savedScope;
      // Dart forbids falling out of a non-empty case; emit the implicit break.
      if (members[i].statements.isNotEmpty && i != members.length - 1) {
        _b.emitJmp(end);
      }
    }
    _loops.removeLast();
    _b.bind(end);
    _top = mark;
  }

  void _compileDoWhile(DoStatement s) {
    final bodyLabel = _b.newLabel();
    final condLabel = _b.newLabel(); // `continue` target: re-test the condition
    final endLabel = _b.newLabel();
    _b.bind(bodyLabel);
    _pushLoop(condLabel, endLabel);
    _compileStatement(s.body);
    _loops.removeLast();
    _b.bind(condLabel);
    final mark = _top;
    final cond = _compileOperand(s.condition);
    _b.emitBranch(
      Op.jnz,
      cond,
      bodyLabel,
    ); // loop back while the condition holds
    _top = mark;
    _b.bind(endLabel);
  }

  void _compileFor(ForStatement s) {
    final parts = s.forLoopParts;
    if (parts is ForEachParts) {
      _compileForEach(s, parts);
      return;
    }
    if (s.awaitKeyword != null) {
      _unsupported(s, '`await for` requires a for-in loop');
    }
    if (parts is! ForParts) {
      _unsupported(s, 'this for-loop form is not yet supported');
    }
    final savedTop = _top;
    final savedScope = _scope;
    _scope = [];

    switch (parts) {
      case ForPartsWithDeclarations():
        _compileVariableDeclarationList(parts.variables);
      case ForPartsWithExpression():
        final init = parts.initialization;
        if (init != null) {
          final mark = _top;
          _compileExpressionForEffect(init);
          _top = mark;
        }
      default:
        _unsupported(s, 'this for-loop form is not yet supported');
    }

    final condLabel = _b.newLabel();
    final continueLabel = _b.newLabel();
    final endLabel = _b.newLabel();
    _b.bind(condLabel);
    final condition = parts.condition;
    if (condition != null) {
      final mark = _top;
      final cond = _compileOperand(condition);
      _b.emitBranch(Op.jz, cond, endLabel);
      _top = mark;
    }
    _pushLoop(continueLabel, endLabel);
    _compileStatement(s.body);
    _loops.removeLast();
    _b.bind(continueLabel);
    for (final updater in parts.updaters) {
      final mark = _top;
      _compileExpressionForEffect(updater);
      _top = mark;
    }
    _b.emitJmp(condLabel);
    _b.bind(endLabel);

    for (final element in _scope) {
      _locals.remove(element);
    }
    _scope = savedScope;
    _top = savedTop;
  }

  /// `for (var x in iterable) body` via the Iterator protocol dispatched
  /// through the host bridge (`iterator`, `moveNext`, `current`).
  void _compileForEach(ForStatement s, ForEachParts parts) {
    final savedTop = _top;
    final savedScope = _scope;
    _scope = [];

    final int loopReg;
    switch (parts) {
      case ForEachPartsWithDeclaration():
        final element = parts.loopVariable.declaredFragment?.element;
        if (element == null) {
          _unsupported(s, 'loop variable has no resolved element');
        }
        loopReg = _alloc();
        _locals[element] = loopReg;
        _scope.add(element);
      case ForEachPartsWithIdentifier():
        final reg = _locals[parts.identifier.element];
        if (reg == null) {
          _unsupported(s, 'for-in target must be a local variable');
        }
        loopReg = reg;
      default:
        _unsupported(s, 'this for-in form is not yet supported');
    }

    final iteratorReg = _alloc();
    final setup = _top;
    var iterableReg = _compileOperand(parts.iterable);
    if (s.awaitKeyword != null) {
      // `await for (x in stream)`: eagerly drain the stream to a list, then
      // iterate it synchronously. Finite streams behave exactly; infinite ones
      // do not terminate (the eager-generator limitation).
      final listReg = _alloc();
      _emitInvoke(listReg, iterableReg, 'toList', const []);
      _b.emitA(Op.awaitValue, listReg);
      iterableReg = listReg;
    }
    _emitInvoke(iteratorReg, iterableReg, 'iterator', const []);
    _top = setup;

    final loopLabel = _b.newLabel();
    final endLabel = _b.newLabel();
    _b.bind(loopLabel);
    final hasNext = _alloc();
    _emitInvoke(hasNext, iteratorReg, 'moveNext', const []);
    _b.emitBranch(Op.jz, hasNext, endLabel);
    _top = setup;
    _emitInvoke(loopReg, iteratorReg, 'current', const []);

    _pushLoop(loopLabel, endLabel);
    _compileStatement(s.body);
    _loops.removeLast();
    _b.emitJmp(loopLabel);
    _b.bind(endLabel);

    for (final element in _scope) {
      _locals.remove(element);
    }
    _scope = savedScope;
    _top = savedTop;
  }

  void _compileReturn(ReturnStatement s) {
    // In a generator, `return;` ends iteration (a value is disallowed by the
    // analyzer): run finallys and emit `ret.void`, which the driver reads as
    // "no more elements".
    if (_isGenerator) {
      _runPendingFinallys(0);
      _b.emitNone(Op.retVoid);
      return;
    }
    final expr = s.expression;
    if (expr == null) {
      _runPendingFinallys(0);
      _b.emitNone(Op.retVoid);
      return;
    }
    final mark = _top;
    final r = _compileOperand(expr);
    if (_finallys.isEmpty) {
      _b.emitA(Op.ret, r);
      _top = mark;
      return;
    }
    // A `return` inside a `try`/`finally` must run every enclosing finally
    // block first. Hold the value in a register those blocks won't clobber
    // (finally code allocates above `hold`), then return it.
    final hold = _alloc();
    _b.emitAB(Op.move, hold, r);
    _runPendingFinallys(0);
    _b.emitA(Op.ret, hold);
    _top = mark;
  }

  /// Emits fresh inline copies of every `finally` block from the top of the
  /// stack down to (and including) [downTo], innermost first. Used on the
  /// non-local exit paths (`return`/`break`/`continue`). While a block is
  /// emitted, the stack is sliced so a nested exit inside it sees only the
  /// finallys strictly enclosing it; the full stack is restored afterward so
  /// the normal fall-through path is unaffected.
  void _runPendingFinallys(int downTo) {
    if (_finallys.length <= downTo) return;
    final saved = List<_FinallyContext>.of(_finallys);
    for (var i = saved.length - 1; i >= downTo; i--) {
      _finallys
        ..clear()
        ..addAll(saved.take(i));
      saved[i].emit();
    }
    _finallys
      ..clear()
      ..addAll(saved);
  }

  /// Lowers `try`/`catch`/`finally`. Without a `finally`, the try body is a
  /// protected region whose handler dispatches over the catch clauses. With a
  /// `finally`, an outer catch-all region wraps the whole thing: the finally
  /// block runs on normal completion, on the exceptional path (then re-raises),
  /// and on every non-local exit out of the try/catch.
  void _compileTry(TryStatement s) {
    final afterAll = _b.newLabel();
    final finallyBlock = s.finallyBlock;

    if (finallyBlock == null) {
      _emitTryCatch(s, afterAll);
      _b.bind(afterAll);
      return;
    }

    void emitFinally() => _compileBlock(finallyBlock);

    final mark = _top;
    final fexc = _alloc(); // holds the in-flight exception at the landing
    final protectStart = _b.newLabel();
    final protectEnd = _b.newLabel();
    final finallyLanding = _b.newLabel();
    final normalFinally = _b.newLabel();

    _finallys.add(_FinallyContext(emitFinally));
    _b.bind(protectStart);
    _emitTryCatch(s, normalFinally);
    _b.bind(protectEnd);
    _finallys.removeLast();
    // Added after the inner try/catch handler so that handler (registered by
    // _emitTryCatch) keeps priority for body throws; this one catches throws
    // from the catch clauses and the uncaught-rethrow tail.
    _b.addHandler(protectStart, protectEnd, finallyLanding, fexc);

    // Normal / handled completion: run finally, continue past the statement.
    _b.bind(normalFinally);
    emitFinally();
    _b.emitJmp(afterAll);

    // Exceptional path: outside the protected region now, run finally and
    // re-raise the original exception to the next enclosing handler.
    _b.bind(finallyLanding);
    emitFinally();
    _b.emitA(Op.throwValue, fexc);

    _b.bind(afterAll);
    _top = mark;
  }

  /// Emits the try body and its catch-clause dispatch. Normal completion of the
  /// body or of a matched clause jumps to [onNormal]. A registered handler
  /// routes a body throw to the dispatch chain, which tests each clause's type
  /// in turn and re-raises if none match (unless a clause is a catch-all).
  void _emitTryCatch(TryStatement s, Label onNormal) {
    final clauses = s.catchClauses;
    if (clauses.isEmpty) {
      _compileBlock(s.body);
      _b.emitJmp(onNormal);
      return;
    }

    final mark = _top;
    final exc = _alloc(); // receives the thrown value from the handler
    final bodyStart = _b.newLabel();
    final bodyEnd = _b.newLabel();
    final dispatch = _b.newLabel();

    _b.bind(bodyStart);
    _compileBlock(s.body);
    _b.bind(bodyEnd);
    _b.emitJmp(onNormal);
    _b.addHandler(bodyStart, bodyEnd, dispatch, exc);

    _b.bind(dispatch);
    _catchRegs.add(exc);
    var sawCatchAll = false;
    for (final clause in clauses) {
      _emitCatchClause(clause, exc, onNormal);
      if (clause.exceptionType == null) {
        sawCatchAll = true;
        break; // clauses after an untyped catch are unreachable
      }
    }
    _catchRegs.removeLast();
    // No clause matched: re-raise. (Unreachable when a catch-all is present.)
    if (!sawCatchAll) _b.emitA(Op.throwValue, exc);
    _top = mark;
  }

  /// Emits one catch clause: an optional `on T` type guard, binding of the
  /// exception (and stack-trace) parameters, the clause body, and a jump to
  /// [onNormal]. A guarded clause that does not match falls through to the next.
  void _emitCatchClause(CatchClause clause, int exc, Label onNormal) {
    final next = _b.newLabel();
    final typeNode = clause.exceptionType;
    if (typeNode != null) {
      final mark = _top;
      final test = _alloc();
      _b.emitAB(Op.move, test, exc);
      _b.emitABx(Op.isType, test, _constants.add(_typeSpec(typeNode.type)));
      _b.emitBranch(Op.jz, test, next); // not this type: try the next clause
      _top = mark;
    }

    final savedScope = _scope;
    _scope = [];

    final excParam = clause.exceptionParameter;
    if (excParam != null) {
      final element = excParam.declaredFragment?.element;
      if (element == null) {
        _unsupported(excParam, 'catch parameter has no resolved element');
      }
      // Bind the exception to its own register so a nested closure can box it
      // if it captures it, independent of the shared handler register.
      final reg = _alloc();
      _b.emitAB(Op.move, reg, exc);
      _locals[element] = reg;
      _scope.add(element);
      _maybeBox(element, reg);
    }

    final stParam = clause.stackTraceParameter;
    if (stParam != null) {
      final element = stParam.declaredFragment?.element;
      if (element == null) {
        _unsupported(stParam, 'stack-trace parameter has no resolved element');
      }
      // Stack traces are not reified by the interpreter; bind to null so code
      // that names the parameter still compiles.
      final reg = _alloc();
      _b.emitA(Op.loadNull, reg);
      _locals[element] = reg;
      _scope.add(element);
      _maybeBox(element, reg);
    }

    _compileBlock(clause.body);
    _b.emitJmp(onNormal);

    for (final element in _scope) {
      _locals.remove(element);
    }
    _scope = savedScope;
    _b.bind(next);
  }

  /// Evaluates [e] for its side effects, discarding the value.
  void _compileExpressionForEffect(Expression e) {
    if (e is AssignmentExpression) {
      _compileAssignment(e, null);
      return;
    }
    // `x++` / `++x` in statement or for-updater position: increment in place
    // with no result register and no move.
    if (e is PostfixExpression && _isIncDec(e.operator.type)) {
      _incDecInPlace(e.operand, e.operator.type, e);
      return;
    }
    if (e is PrefixExpression && _isIncDec(e.operator.type)) {
      _incDecInPlace(e.operand, e.operator.type, e);
      return;
    }
    final t = _alloc();
    _compileExprInto(e, t);
  }

  // --- Expressions ---

  /// Returns a register holding the value of [e], reading a local in place
  /// without allocating when possible.
  int _compileOperand(Expression e) {
    if (e is ParenthesizedExpression) return _compileOperand(e.expression);
    if (e is SimpleIdentifier) {
      final element = e.element;
      final reg = _locals[element];
      if (reg != null) {
        // A boxed variable's register holds a cell, not the value; read it out.
        if (!_boxed.contains(element)) return reg;
        final t = _alloc();
        _b.emitAB(Op.cellGet, t, reg);
        return t;
      }
    }
    final t = _alloc();
    _compileExprInto(e, t);
    return t;
  }

  void _compileExprInto(Expression e, int dest) {
    // Constant folding: collapse a constant subexpression to a single load.
    final folded = _constFold(e);
    if (!identical(folded, _notConst)) {
      _emitConst(dest, folded);
      return;
    }
    switch (e) {
      case IntegerLiteral():
        final value = e.value;
        if (value == null) {
          _unsupported(e, 'integer literal is out of range');
        }
        _loadInt(dest, value);
      case DoubleLiteral():
        _loadConstValue(dest, e.value);
      case BooleanLiteral():
        _b.emitA(e.value ? Op.loadTrue : Op.loadFalse, dest);
      case NullLiteral():
        _b.emitA(Op.loadNull, dest);
      case SimpleStringLiteral():
        _loadConstValue(dest, e.value);
      case ParenthesizedExpression():
        _compileExprInto(e.expression, dest);
      case SimpleIdentifier():
        _compileIdentifierInto(e, dest);
      case PrefixExpression():
        _compilePrefixInto(e, dest);
      case PostfixExpression():
        _compilePostfixInto(e, dest);
      case BinaryExpression():
        _compileBinaryInto(e, dest);
      case ConditionalExpression():
        _compileConditionalInto(e, dest);
      case AssignmentExpression():
        _compileAssignment(e, dest);
      case MethodInvocation():
        _compileInvocationInto(e, dest);
      case StringInterpolation():
        _compileStringInterpolation(e, dest);
      case AdjacentStrings():
        _compileAdjacentStrings(e, dest);
      case ListLiteral():
        _compileListLiteral(e, dest);
      case SetOrMapLiteral():
        _compileSetOrMapLiteral(e, dest);
      case RecordLiteral():
        _compileRecordLiteral(e, dest);
      case IndexExpression():
        _compileIndexInto(e, dest);
      case PropertyAccess():
        _compilePropertyGet(
          e.realTarget,
          e.propertyName.name,
          e.isNullAware,
          dest,
          e,
        );
      case PrefixedIdentifier():
        _compilePrefixedIdentifier(e, dest);
      case ThisExpression():
        if (_enclosingClass == null && !_isExtension) {
          _unsupported(e, '`this` is only valid inside an instance method');
        }
        if (dest != _thisReg) _b.emitAB(Op.move, dest, _thisReg);
      case InstanceCreationExpression():
        _compileInstanceCreation(e, dest);
      case FunctionExpression():
        _compileFunctionExpressionInto(e, dest);
      case FunctionExpressionInvocation():
        _compileFunctionExpressionInvocation(e, dest);
      case AwaitExpression():
        // `await` is valid in an `async` function or an `async*` generator (both
        // run on the event loop); a `sync*` generator cannot suspend on a
        // future.
        if (!_isAsync && !_isAsyncStar) {
          _unsupported(
            e,
            '`await` is only valid in an `async` or `async*` function',
          );
        }
        _compileExprInto(e.expression, dest);
        _b.emitA(Op.awaitValue, dest);
      case CascadeExpression():
        _compileCascadeInto(e, dest);
      case SwitchExpression():
        _compileSwitchExpressionInto(e, dest);
      case IsExpression():
        _compileExprInto(e.expression, dest);
        _b.emitABx(Op.isType, dest, _constants.add(_typeSpec(e.type.type)));
        if (e.notOperator != null) _b.emitAB(Op.not, dest, dest);
      case AsExpression():
        _compileExprInto(e.expression, dest);
        _b.emitABx(Op.asType, dest, _constants.add(_typeSpec(e.type.type)));
      case ThrowExpression():
        // `throw` has type Never: it transfers control and never yields a value
        // into `dest`, so nothing writes it.
        final r = _compileOperand(e.expression);
        _b.emitA(Op.throwValue, r);
      case RethrowExpression():
        if (_catchRegs.isEmpty) {
          _unsupported(e, '`rethrow` is only valid inside a catch clause');
        }
        _b.emitA(Op.throwValue, _catchRegs.last);
      case FunctionReference():
        // A generic instantiation `f<int>` erases to the function reference `f`,
        // since type arguments do not exist at runtime.
        _compileExprInto(e.function, dest);
      case TypeLiteral():
        // A type used as a value is represented by its name (the same string
        // `runtimeType` yields), so `x.runtimeType == T` works for core types.
        _loadConstValue(dest, _typeSpec(e.type.type));
      case SymbolLiteral():
        final name = e.components.map((t) => t.lexeme).join('.');
        final mark = _top;
        final mapReg = _alloc();
        _b.emitA(Op.mapNew, mapReg);
        final keyReg = _alloc();
        _loadConstValue(keyReg, 'name');
        final valReg = _alloc();
        _loadConstValue(valReg, name);
        _emitInvoke(null, mapReg, '[]=', [keyReg, valReg]);
        _b.emitABx(Op.invokeStatic, mapReg, _callSite('Symbol', 1));
        if (dest != mapReg) _b.emitAB(Op.move, dest, mapReg);
        _top = mark;
      default:
        _unsupported(e, 'expression `${astKindName(e)}` is not yet supported');
    }
  }

  // --- Classes ---

  void _compileInstanceCreation(InstanceCreationExpression e, int dest) {
    final classElement = e.staticType?.element;
    // An extension type erases to its representation: `Meters(5)` is just `5`.
    if (classElement != null && _extensionTypes.containsKey(classElement)) {
      final args = e.argumentList.arguments;
      if (args.length == 1 && args.first is! NamedArgument) {
        _compileExprInto(args.first.argumentExpression, dest);
        return;
      }
    }
    final layout = classElement == null ? null : _classLayouts[classElement];
    if (layout == null) {
      // A construction of a type not defined in this unit (e.g. `Future.value`)
      // dispatches to a host global named `Type` or `Type.namedConstructor`,
      // validated against the host allow-list at runtime — the same boundary as
      // host method calls, and the hook a Flutter bridge registers against.
      _compileHostConstruction(e, dest, classElement?.name);
      return;
    }
    final params =
        e.constructorName.element?.formalParameters ??
        const <FormalParameterElement>[];
    final ctorName = e.constructorName.name?.name ?? '';
    final ctorIndex = layout.constructors[ctorName];
    if (ctorIndex == null) {
      _unsupported(e, 'constructor `$ctorName` not found');
    }
    final args = e.argumentList.arguments;
    final mark = _top;

    if (layout.factories.contains(ctorName)) {
      // A factory returns the instance itself; call it with no receiver.
      final callBase = _alloc();
      for (var i = 0; i < params.length; i++) {
        _alloc();
      }
      _b.emitABx(Op.loadFunc, callBase, ctorIndex);
      _emitArgsInParamOrder(callBase + 1, params, args);
      _b.emitABC(Op.call, callBase, 0, params.length);
      if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
      _top = mark;
      return;
    }

    final instanceReg = _alloc();
    _b.emitABx(Op.alloc, instanceReg, layout.classIndex);
    // Constructor call convention: callee, then this, then one slot per
    // constructor parameter (named/optional reordered, defaults filled by the
    // constructor prologue).
    final callBase = _alloc();
    _b.emitABx(Op.loadFunc, callBase, ctorIndex);
    _alloc(); // callBase+1 = this
    _b.emitAB(Op.move, callBase + 1, instanceReg);
    for (var i = 0; i < params.length; i++) {
      _alloc(); // callBase + 2 + i
    }
    _emitArgsInParamOrder(callBase + 2, params, args);
    _b.emitABC(Op.call, callBase, 0, params.length + 1);
    if (dest != instanceReg) _b.emitAB(Op.move, dest, instanceReg);
    _top = mark;
  }

  /// Lowers construction of a type not defined in this unit to a host global
  /// call. The selector is the type name, or `Type.namedConstructor` for a named
  /// constructor (e.g. `Future.value`). Arguments are positional; named
  /// arguments to host constructors are a follow-up (the Flutter bridge will
  /// carry them).
  void _compileHostConstruction(
    InstanceCreationExpression e,
    int dest,
    String? typeName,
  ) {
    if (typeName == null) {
      _unsupported(e, 'cannot resolve the constructed type');
    }
    final ctorName = e.constructorName.name?.name;
    final selector = ctorName != null ? '$typeName.$ctorName' : typeName;
    _emitHostCall(dest, selector, e.argumentList.arguments);
  }

  /// Emits a host global call whose single argument is a `Map<String, Object?>`
  /// of `{parameterName: value}` for every provided argument. This is the
  /// calling convention for host constructors and static methods (`Text(...)`,
  /// `int.parse(...)`): it carries named and positional arguments uniformly —
  /// each keyed by its resolved parameter name — so a host binding reads
  /// `args['child']`, `args['style']`, etc. It is the surface a framework bridge
  /// binds against (`spec/host-api.md`).
  void _emitHostCall(int dest, String selector, List<Argument> args) {
    final mark = _top;
    final mapReg = _alloc();
    _b.emitA(Op.mapNew, mapReg);
    for (final arg in args) {
      final param = arg.correspondingParameter;
      if (param == null) {
        _unsupported(arg, 'argument does not resolve to a parameter');
      }
      final name = param.name;
      if (name == null) {
        _unsupported(arg, 'parameter has no name');
      }
      final inner = _top;
      final keyReg = _alloc();
      _loadConstValue(keyReg, name);
      final valReg = _alloc();
      _compileExprInto(arg.argumentExpression, valReg);
      _emitInvoke(null, mapReg, '[]=', [keyReg, valReg]);
      _top = inner;
    }
    _b.emitABx(Op.invokeStatic, mapReg, _callSite(selector, 1));
    if (dest != mapReg) _b.emitAB(Op.move, dest, mapReg);
    _top = mark;
  }

  /// Emits one value per callee parameter into consecutive registers starting
  /// at [base] (already allocated), mapping each argument to its parameter via
  /// the analyzer's resolution. An omitted optional parameter gets the absent
  /// sentinel (`load.undef`); the callee's prologue substitutes its default.
  /// This is what makes named and optional arguments work for calls to
  /// functions and constructors defined in this unit.
  void _emitArgsInParamOrder(
    int base,
    List<FormalParameterElement> params,
    List<Argument> args,
  ) {
    // Match by name (named) and position (positional) rather than by the
    // `correspondingParameter` element, whose identity differs from the
    // declaration's under generic instantiation (`Box<int>(…)`).
    final byName = <String, Expression>{};
    final positional = <Expression>[];
    for (final arg in args) {
      if (arg is NamedArgument) {
        byName[_namedArgLabel(arg)] = arg.argumentExpression;
      } else {
        positional.add(arg.argumentExpression);
      }
    }
    var posIdx = 0;
    for (var i = 0; i < params.length; i++) {
      final param = params[i];
      final expr = param.isNamed
          ? byName[param.name]
          : (posIdx < positional.length ? positional[posIdx++] : null);
      if (expr != null) {
        _compileExprInto(expr, base + i);
      } else {
        _b.emitA(Op.loadUndef, base + i);
      }
    }
  }

  /// Reorders a host method's named/positional [args] into positional order per
  /// [params], returning the argument registers. Host methods take positional
  /// arguments and supply their own defaults, so trailing unprovided parameters
  /// are dropped; a gap (an unprovided parameter before a provided one) is
  /// reported rather than mis-passed.
  List<int> _hostArgsInParamOrder(
    List<FormalParameterElement> params,
    List<Argument> args,
  ) {
    final byName = <String, Expression>{};
    final positional = <Expression>[];
    for (final arg in args) {
      if (arg is NamedArgument) {
        byName[_namedArgLabel(arg)] = arg.argumentExpression;
      } else {
        positional.add(arg.argumentExpression);
      }
    }
    final provided = <Expression?>[];
    var posIdx = 0;
    var lastProvided = -1;
    for (var i = 0; i < params.length; i++) {
      final p = params[i];
      final expr = p.isNamed
          ? byName[p.name]
          : (posIdx < positional.length ? positional[posIdx++] : null);
      provided.add(expr);
      if (expr != null) lastProvided = i;
    }
    final regs = <int>[];
    for (var i = 0; i <= lastProvided; i++) {
      final expr = provided[i];
      if (expr != null) {
        regs.add(_compileOperand(expr));
        continue;
      }
      // A skipped optional before a provided argument is filled with its
      // constant default, so the host method receives it positionally.
      final value = params[i].computeConstantValue();
      final dartValue = value == null || value.isNull
          ? null
          : value.toIntValue() ??
                value.toDoubleValue() ??
                value.toBoolValue() ??
                value.toStringValue();
      if (value == null || (dartValue == null && !value.isNull)) {
        _unsupported(
          args.first,
          'skipping an optional argument with a non-constant default on a host '
          'method is not yet supported',
        );
      }
      final reg = _alloc();
      _emitConst(reg, dartValue);
      regs.add(reg);
    }
    return regs;
  }

  /// The parameter name a named argument binds to (its label without the colon).
  String _namedArgLabel(NamedArgument arg) {
    final lexeme = arg.name.lexeme;
    return lexeme.endsWith(':')
        ? lexeme.substring(0, lexeme.length - 1)
        : lexeme;
  }

  // --- Closures ---

  /// Lowers a function expression to a closure: compiles its body as a fresh
  /// module function that captures the enclosing variables it refers to, then
  /// emits `closure.new` to build the runtime closure over those cells.
  void _compileFunctionExpressionInto(FunctionExpression fe, int dest) {
    final capThis = capturesThis(fe.body);
    if (capThis && _thisCellReg < 0) {
      // The enclosing scope has no `this` to capture (e.g. a nested closure two
      // levels deep from the method). Not yet supported; reported rather than
      // mis-lowered.
      _unsupported(
        fe,
        'capturing `this` is only supported directly inside a method or '
        'constructor',
      );
    }
    // Free variables of the closure among the enclosing scope's locals, in a
    // deterministic (first-appearance) order. Each is captured by cell, so the
    // enclosing function must already have boxed it (capture analysis ensured
    // this by adding it to `_captured`).
    final upvalueElements = freeVariables(fe.body, _locals.keys.toSet());
    final captures = <int>[];
    final upvalueMap = <Element, int>{};
    for (var i = 0; i < upvalueElements.length; i++) {
      final element = upvalueElements[i];
      captures.add(_locals[element]!);
      upvalueMap[element] = i;
    }
    // Append `this` as one more captured cell when the closure needs it.
    var thisUpvalue = -1;
    if (capThis) {
      thisUpvalue = captures.length;
      captures.add(_thisCellReg);
    }

    final index = _sink.reserve();
    final child = FunctionCompiler(
      constants: _constants,
      functionIndices: _functionIndices,
      callSites: _callSites,
      path: _path,
      lineInfo: _lineInfo,
      diagnostics: _diagnostics,
      sink: _sink,
      classLayouts: _classLayouts,
      enclosingClass: capThis ? _enclosingClass : null,
      upvalues: upvalueMap,
      thisUpvalue: thisUpvalue,
      enumValues: _enumValues,
      enumMembers: _enumMembers,
    );
    try {
      _sink.place(index, child.compileClosure(fe, captures));
    } on AbortCompilation {
      // Keep the reserved slot gap-free; the recorded diagnostic already dooms
      // the compile, so this stub is never executed.
      _sink.place(
        index,
        (BytecodeBuilder()..emitNone(Op.retVoid)).toProto(
          name: '<closure:error>',
          paramCount: 0,
          registerCount: 1,
        ),
      );
      rethrow;
    }
    _b.emitABx(Op.closureNew, dest, index);
  }

  /// Compiles `expr(args)` where `expr` evaluates to a callable (a closure value
  /// or a function reference).
  void _compileFunctionExpressionInvocation(
    FunctionExpressionInvocation e,
    int dest,
  ) {
    _compileValueCall(e.function, e.argumentList.arguments, dest);
  }

  /// Emits a direct call to the unit function at [index] (a top-level or static
  /// method), reordering [args] into [params] order with defaults filled.
  void _compileStaticCall(
    int index,
    List<FormalParameterElement> params,
    List<Argument> args,
    int dest,
  ) {
    final mark = _top;
    final callBase = _alloc();
    for (var i = 0; i < params.length; i++) {
      _alloc();
    }
    _b.emitABx(Op.loadFunc, callBase, index);
    _emitArgsInParamOrder(callBase + 1, params, args);
    _b.emitABC(Op.call, callBase, 0, params.length);
    if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
    _top = mark;
  }

  /// Whether an instance call should take the parameter-order path (which fills
  /// defaults): true when [method] is declared in this unit and the call uses a
  /// named argument, omits an optional, or the method has optional/named params.
  bool _hasNamedOrOptional(List<Argument> args, Element? method) {
    if (method is! MethodElement || method.isStatic) return false;
    if (!_classLayouts.containsKey(method.enclosingElement)) return false;
    final params = method.formalParameters;
    return args.any((a) => a is NamedArgument) ||
        params.any((p) => p.isOptional) ||
        args.length < params.length;
  }

  /// Compiles `receiver.method(args)` for a unit-declared method, reordering
  /// named/optional arguments into parameter slots (absent ones get the
  /// sentinel, which the method prologue replaces with the default) and
  /// dispatching with `invoke.dyn`.
  void _compileNamedInstanceCall(
    MethodInvocation e,
    MethodElement method,
    int dest,
  ) {
    final params = method.formalParameters;
    final args = e.argumentList.arguments;
    final selector = e.methodName.name;
    final mark = _top;
    final base = _alloc(); // receiver
    for (var i = 0; i < params.length; i++) {
      _alloc(); // one slot per parameter
    }
    _compileExprInto(e.realTarget!, base);
    void invoke() {
      _emitArgsInParamOrder(base + 1, params, args);
      _b.emitABx(Op.invokeDyn, base, _callSite(selector, params.length));
      if (dest != base) _b.emitAB(Op.move, dest, base);
    }

    if (e.isNullAware) {
      _compileNullAwareChain(base, dest, invoke);
    } else {
      invoke();
    }
    _top = mark;
  }

  /// Emits a dynamic call of the value produced by [calleeExpr] with [args].
  /// The callee value and its arguments occupy a fresh contiguous block so
  /// live registers are never clobbered.
  void _compileValueCall(Expression calleeExpr, List<Argument> args, int dest) {
    for (final arg in args) {
      if (arg is NamedArgument) {
        _unsupported(arg, 'named arguments are not yet supported');
      }
    }
    final mark = _top;
    final callBase = _alloc();
    _compileExprInto(calleeExpr, callBase);
    for (var i = 0; i < args.length; i++) {
      final slot = _alloc();
      _compileExprInto(args[i].argumentExpression, slot);
    }
    _b.emitABC(Op.call, callBase, 0, args.length);
    if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
    _top = mark;
  }

  /// The field slot for [name] on a receiver of [type], or `null` if [type] is
  /// not a class in this unit or has no such stored field.
  int? _fieldSlotOf(DartType? type, String name) {
    final element = type?.element;
    if (element == null) return null;
    return _classLayouts[element]?.fieldsByName[name];
  }

  // --- Property access and dynamic method invocation ---

  void _compilePrefixedIdentifier(PrefixedIdentifier e, int dest) {
    // `a.b` where `a` is an identifier. If `a` is a local/parameter, this is an
    // instance getter.
    if (_locals.containsKey(e.prefix.element)) {
      _compilePropertyGet(e.prefix, e.identifier.name, false, dest, e);
      return;
    }
    // `C.x` where `x` is a static field: read its module global.
    final staticGlobal = _staticGlobalFor(e.identifier.element);
    if (staticGlobal != null) {
      _b.emitABx(Op.loadGlobal, dest, staticGlobal);
      return;
    }
    // `C.f` where `f` is a static method of a unit class: a function tear-off.
    final staticFn = _functionIndices[e.identifier.element];
    if (staticFn != null && e.prefix.element is InterfaceElement) {
      _b.emitABx(Op.loadFunc, dest, staticFn);
      return;
    }
    // A member of a user-defined enum via its type: `Color.red` (a single
    // interned constant) or `Color.values` (a fresh list of all values).
    final enumList = _enumMembers[e.prefix.element];
    if (enumList != null) {
      final name = e.identifier.name;
      if (name == 'values') {
        final mark = _top;
        _b.emitA(Op.listNew, dest);
        for (final v in enumList) {
          final valReg = _alloc();
          _b.emitABx(Op.loadConst, valReg, _constants.add(v));
          _emitInvoke(null, dest, 'add', [valReg]);
          _top = mark + 1; // keep the list; free the temp
        }
        _top = mark;
        return;
      }
      for (final v in enumList) {
        if (v.name == name) {
          _b.emitABx(Op.loadConst, dest, _constants.add(v));
          return;
        }
      }
    }
    // `Type.member` where `Type` is a class or enum: a static getter or enum
    // value (`Colors.blue`, `MainAxisAlignment.center`). Dispatch to a host
    // global named `Type.member`, validated against the allow-list at runtime.
    if (e.prefix.element is InterfaceElement) {
      final selector = '${e.prefix.name}.${e.identifier.name}';
      _b.emitABx(Op.invokeStatic, dest, _callSite(selector, 0));
      return;
    }
    _unsupported(
      e,
      'static or library access `${e.name}` is not yet supported',
      correction: 'instance getters on values are supported',
    );
  }

  void _compilePropertyGet(
    Expression? receiver,
    String name,
    bool nullAware,
    int dest,
    AstNode node,
  ) {
    if (receiver == null) {
      _unsupported(node, 'implicit-receiver access is not yet supported');
    }
    // `super.x`: an inherited field is read from `this`'s slot; a super getter
    // dispatches statically to the superclass implementation.
    if (receiver is SuperExpression) {
      final slot = _enclosingClass?.fieldsByName[name];
      if (slot != null) {
        _b.emitABC(Op.loadField, dest, _thisReg, slot);
        return;
      }
      final superIndex = _methodIndices[_propertyElement(node)];
      if (superIndex == null) {
        _unsupported(node, 'super member `$name` not found');
      }
      final mark = _top;
      final callBase = _alloc();
      _alloc(); // callBase+1 = this
      _b
        ..emitABx(Op.loadFunc, callBase, superIndex)
        ..emitAB(Op.move, callBase + 1, _thisReg)
        ..emitABC(Op.call, callBase, 0, 1);
      if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
      _top = mark;
      return;
    }
    final mark = _top;
    final receiverReg = _compileOperand(receiver);
    final slot = _fieldSlotOf(receiver.staticType, name);
    final isRecord = receiver.staticType is RecordType;
    final member = _propertyElement(node);
    final tearOff = member is MethodElement ? _tearOffArity(member) : null;
    final extGetter = _functionIndices[member];
    // `m.value` where `value` is an extension type's representation is identity.
    final isExtTypeRep = _extensionTypes[receiver.staticType?.element] == name;
    void access() {
      if (isExtTypeRep) {
        if (dest != receiverReg) _b.emitAB(Op.move, dest, receiverReg);
      } else if (isRecord) {
        // Record field access: `$1`/`$2`/… positional or a named field.
        if (dest != receiverReg) _b.emitAB(Op.move, dest, receiverReg);
        _b.emitABx(Op.recordGet, dest, _constants.add(name));
      } else if (extGetter != null) {
        // Extension getter: static call with the receiver as the argument.
        final mark2 = _top;
        final callBase = _alloc();
        final recvSlot = _alloc();
        _b
          ..emitABx(Op.loadFunc, callBase, extGetter)
          ..emitAB(Op.move, recvSlot, receiverReg)
          ..emitABC(Op.call, callBase, 0, 1);
        if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
        _top = mark2;
      } else if (slot != null) {
        _b.emitABC(Op.loadField, dest, receiverReg, slot);
      } else if (member is MethodElement) {
        // `obj.method` (not called): a bound-method tear-off.
        if (tearOff == null) {
          _unsupported(
            node,
            'tearing off a method with optional/named parameters is not yet '
            'supported',
          );
        }
        _emitMethodTearOff(receiverReg, tearOff, name, dest);
      } else {
        _emitInvoke(dest, receiverReg, name, const []);
      }
    }

    if (nullAware) {
      _compileNullAwareChain(receiverReg, dest, access);
    } else {
      access();
    }
    _top = mark;
  }

  /// Lowers a record literal `(a, b, name: c)` to `record.new`: the positional
  /// fields (in order) then the named fields (in source order) are evaluated
  /// into a contiguous register block, and a shape string encodes the arity and
  /// named-field order for the runtime.
  void _compileRecordLiteral(RecordLiteral e, int dest) {
    final positional = <Expression>[];
    final named = <String, Expression>{};
    for (final field in e.fields) {
      if (field is RecordLiteralNamedField) {
        named[field.name.lexeme] = field.fieldExpression;
      } else {
        positional.add(field.fieldExpression);
      }
    }

    final mark = _top;
    final base = _alloc();
    final total = positional.length + named.length;
    for (var i = 1; i < total; i++) {
      _alloc(); // reserve the rest of the contiguous field block
    }
    var idx = 0;
    for (final p in positional) {
      _compileExprInto(p, base + idx);
      idx++;
    }
    for (final v in named.values) {
      _compileExprInto(v, base + idx);
      idx++;
    }
    final shape = named.isEmpty
        ? '${positional.length}'
        : '${positional.length};${named.keys.join(',')}';
    _b.emitABx(Op.recordNew, base, _constants.add(shape));
    if (dest != base) _b.emitAB(Op.move, dest, base);
    _top = mark;
  }

  /// Lowers a record-destructuring declaration `var (a, b) = e;` (and named
  /// `var (x: a) = e;`): evaluate the record once, then read each field into a
  /// freshly bound local. Only record patterns of simple variable subpatterns
  /// are supported; anything else is reported.
  /// Compiles `var <pattern> = e;`. The pattern is irrefutable (the analyzer
  /// enforces it), so a failed match throws rather than falling through.
  void _compilePatternDeclaration(PatternVariableDeclaration d) {
    final valueReg = _alloc();
    _compileExprInto(d.expression, valueReg);
    final fail = _b.newLabel();
    final ok = _b.newLabel();
    _matchPattern(d.pattern, valueReg, fail);
    _b.emitJmp(ok);
    _b.bind(fail);
    _throwMatchError();
    _b.bind(ok);
    // Bound variables persist (they are in `_scope`); the enclosing block frees
    // every register above its entry mark when the scope exits.
  }

  /// Emits a `throw` of a `StateError`-style message for an unreachable failed
  /// irrefutable match.
  void _throwMatchError() {
    final mark = _top;
    final reg = _alloc();
    _loadConstValue(reg, 'pattern did not match');
    _b.emitA(Op.throwValue, reg);
    _top = mark;
  }

  // --- Pattern matching engine ---

  /// Emits code that matches [valueReg] against [pattern], binding any variables
  /// it declares. On a mismatch it jumps to [fail]; on success control falls
  /// through with the bindings live. Bound-variable and extraction registers are
  /// left allocated (freed by the enclosing scope); only transient test scratch
  /// is reclaimed locally.
  void _matchPattern(DartPattern pattern, int valueReg, Label fail) {
    switch (pattern) {
      case DeclaredVariablePattern():
        _matchTypeGuard(pattern.type?.type, valueReg, fail);
        _bindPatternVariable(
          pattern.declaredFragment?.element,
          valueReg,
          pattern,
        );
      case WildcardPattern():
        _matchTypeGuard(pattern.type?.type, valueReg, fail);
      case ConstantPattern():
        final mark = _top;
        final c = _alloc();
        _compileExprInto(pattern.expression, c);
        final eq = _alloc();
        _b.emitABC(Op.eq, eq, valueReg, c);
        _b.emitBranch(Op.jz, eq, fail);
        _top = mark;
      case ParenthesizedPattern():
        _matchPattern(pattern.pattern, valueReg, fail);
      case LogicalAndPattern():
        _matchPattern(pattern.leftOperand, valueReg, fail);
        _matchPattern(pattern.rightOperand, valueReg, fail);
      case LogicalOrPattern():
        final matched = _b.newLabel();
        final tryRight = _b.newLabel();
        _matchPattern(pattern.leftOperand, valueReg, tryRight);
        _b.emitJmp(matched);
        _b.bind(tryRight);
        _matchPattern(pattern.rightOperand, valueReg, fail);
        _b.bind(matched);
      case RelationalPattern():
        final mark = _top;
        final operand = _alloc();
        _compileExprInto(pattern.operand, operand);
        final res = _alloc();
        _emitInvoke(res, valueReg, pattern.operator.lexeme, [operand]);
        _b.emitBranch(Op.jz, res, fail);
        _top = mark;
      case CastPattern():
        final mark = _top;
        final t = _alloc();
        _b
          ..emitAB(Op.move, t, valueReg)
          ..emitABx(Op.asType, t, _constants.add(_typeSpec(pattern.type.type)));
        _top = mark;
        _matchPattern(pattern.pattern, valueReg, fail);
      case NullCheckPattern():
        _matchNotNull(valueReg, fail);
        _matchPattern(pattern.pattern, valueReg, fail);
      case NullAssertPattern():
        _matchNullAssert(valueReg);
        _matchPattern(pattern.pattern, valueReg, fail);
      case RecordPattern():
        _matchRecordPattern(pattern, valueReg, fail);
      case ListPattern():
        _matchListPattern(pattern, valueReg, fail);
      case MapPattern():
        _matchMapPattern(pattern, valueReg, fail);
      case ObjectPattern():
        _matchTypeGuardSpec(_typeSpec(pattern.type.type), valueReg, fail);
        _matchFields(pattern.fields, valueReg, fail, isRecord: false);
      default:
        _unsupported(pattern, 'this pattern form is not yet supported');
    }
  }

  /// Type-guards [valueReg] against [type] (a no-op for `dynamic`/`Object`).
  void _matchTypeGuard(DartType? type, int valueReg, Label fail) {
    if (type == null) return;
    final spec = _typeSpec(type);
    if (spec == 'Object' || spec == 'Object?' || spec == 'dynamic') return;
    _matchTypeGuardSpec(spec, valueReg, fail);
  }

  void _matchTypeGuardSpec(String spec, int valueReg, Label fail) {
    final mark = _top;
    final t = _alloc();
    _b
      ..emitAB(Op.move, t, valueReg)
      ..emitABx(Op.isType, t, _constants.add(spec));
    _b.emitBranch(Op.jz, t, fail);
    _top = mark;
  }

  /// Binds [element] to a fresh register holding [valueReg]'s value.
  void _bindPatternVariable(Element? element, int valueReg, AstNode node) {
    if (element == null) {
      _unsupported(node, 'pattern variable has no resolved element');
    }
    final reg = _alloc();
    _b.emitAB(Op.move, reg, valueReg);
    _locals[element] = reg;
    _scope.add(element);
    _maybeBox(element, reg);
  }

  void _matchNotNull(int valueReg, Label fail) {
    final mark = _top;
    final nullReg = _alloc();
    _b.emitA(Op.loadNull, nullReg);
    final isNull = _alloc();
    _b.emitABC(Op.eq, isNull, valueReg, nullReg);
    _b.emitBranch(Op.jnz, isNull, fail);
    _top = mark;
  }

  void _matchNullAssert(int valueReg) {
    final mark = _top;
    final nullReg = _alloc();
    _b.emitA(Op.loadNull, nullReg);
    final isNull = _alloc();
    _b.emitABC(Op.eq, isNull, valueReg, nullReg);
    final ok = _b.newLabel();
    _b.emitBranch(Op.jz, isNull, ok);
    final msg = _alloc();
    _loadConstValue(msg, 'Null check operator used on a null value');
    _b.emitA(Op.throwValue, msg);
    _b.bind(ok);
    _top = mark;
  }

  void _matchRecordPattern(RecordPattern p, int valueReg, Label fail) {
    _matchFields(p.fields, valueReg, fail, isRecord: true);
  }

  /// Matches record/object [fields]: each field's value is extracted (via
  /// `record.get` for records or a getter call for objects) and matched against
  /// its sub-pattern. Positional record fields use `$1`, `$2`, ….
  void _matchFields(
    List<PatternField> fields,
    int valueReg,
    Label fail, {
    required bool isRecord,
  }) {
    var posIdx = 1;
    for (final field in fields) {
      final label = field.name?.name?.lexeme;
      final String accessor;
      if (label != null) {
        accessor = label;
      } else if (isRecord && field.name == null) {
        accessor = '\$$posIdx';
        posIdx++;
      } else {
        // Object field shorthand `Point(:var x)` — the field name is the getter.
        final effective = field.effectiveName;
        if (effective == null) {
          _unsupported(field, 'this pattern field is not yet supported');
        }
        accessor = effective;
      }
      final valReg = _alloc();
      if (isRecord) {
        _b
          ..emitAB(Op.move, valReg, valueReg)
          ..emitABx(Op.recordGet, valReg, _constants.add(accessor));
      } else {
        _emitInvoke(valReg, valueReg, accessor, const []);
      }
      _matchPattern(field.pattern, valReg, fail);
    }
  }

  void _matchListPattern(ListPattern p, int valueReg, Label fail) {
    _matchTypeGuardSpec('List', valueReg, fail);
    final elements = p.elements;
    final restIdx = elements.indexWhere((e) => e is RestPatternElement);
    final before = restIdx < 0 ? elements.length : restIdx;
    final after = restIdx < 0 ? 0 : elements.length - restIdx - 1;

    final lenReg = _alloc(); // kept live across the whole list match
    _emitInvoke(lenReg, valueReg, 'length', const []);
    // Length check: exact when there is no rest, else `length >= before+after`.
    final scratch = _top;
    final minReg = _alloc();
    _loadInt(minReg, before + after);
    final ok = _alloc();
    _b.emitABC(restIdx < 0 ? Op.eq : Op.geInt, ok, lenReg, minReg);
    _b.emitBranch(Op.jz, ok, fail);
    _top = scratch;

    // Front elements at indices 0 .. before-1.
    for (var i = 0; i < before; i++) {
      final valReg = _elementAt(valueReg, i);
      _matchPattern(elements[i] as DartPattern, valReg, fail);
    }
    if (restIdx >= 0) {
      final rest = elements[restIdx] as RestPatternElement;
      final restPattern = rest.pattern;
      if (restPattern != null) {
        // The rest binds `list.sublist(before, length - after)`.
        final s = _top;
        final startReg = _alloc();
        _loadInt(startReg, before);
        final endReg = _alloc();
        final afterReg = _alloc();
        _loadInt(afterReg, after);
        _b.emitABC(Op.subInt, endReg, lenReg, afterReg);
        final sliceReg = _alloc();
        _emitInvoke(sliceReg, valueReg, 'sublist', [startReg, endReg]);
        // Keep sliceReg; it may feed bindings. (Scratch below it is reclaimed
        // only after the sub-pattern, so leave _top as is.)
        _matchPattern(restPattern, sliceReg, fail);
        // Reclaim the start/end scratch that sits below sliceReg is unsafe if
        // the sub-pattern bound above; leave allocation to the enclosing scope.
        if (_top < s) _top = s; // never shrink below where we started
      }
      // Back elements: index = length - after + j.
      for (var j = 0; j < after; j++) {
        final idxReg = _alloc();
        final kReg = _alloc();
        _loadInt(kReg, after - j);
        _b.emitABC(Op.subInt, idxReg, lenReg, kReg);
        final valReg = _alloc();
        _emitInvoke(valReg, valueReg, '[]', [idxReg]);
        _matchPattern(elements[restIdx + 1 + j] as DartPattern, valReg, fail);
      }
    }
  }

  /// Extracts `list[i]` for a constant index into a fresh (persisting) register.
  int _elementAt(int listReg, int index) {
    final idxReg = _alloc();
    _loadInt(idxReg, index);
    final valReg = _alloc();
    _emitInvoke(valReg, listReg, '[]', [idxReg]);
    return valReg;
  }

  void _matchMapPattern(MapPattern p, int valueReg, Label fail) {
    _matchTypeGuardSpec('Map', valueReg, fail);
    for (final element in p.elements) {
      if (element is! MapPatternEntry) {
        _unsupported(element, 'this map pattern element is not yet supported');
      }
      // Require the key, then match its value.
      final keyReg = _alloc();
      _compileExprInto(element.key, keyReg);
      final present = _alloc();
      _emitInvoke(present, valueReg, 'containsKey', [keyReg]);
      _b.emitBranch(Op.jz, present, fail);
      final valReg = _alloc();
      _emitInvoke(valReg, valueReg, '[]', [keyReg]);
      _matchPattern(element.value, valReg, fail);
    }
  }

  /// Emits `if (receiverReg == null) dest = null; else <body>`.
  void _compileNullAwareChain(int receiverReg, int dest, void Function() body) {
    final mark = _top;
    final nullReg = _alloc();
    _b.emitA(Op.loadNull, nullReg);
    final cond = _alloc();
    _b.emitABC(Op.eq, cond, receiverReg, nullReg);
    final elseLabel = _b.newLabel();
    final endLabel = _b.newLabel();
    _b.emitBranch(Op.jz, cond, elseLabel); // not null -> body
    _b.emitA(Op.loadNull, dest);
    _b.emitJmp(endLabel);
    _b.bind(elseLabel);
    _top = mark;
    body();
    _b.bind(endLabel);
  }

  void _compileIndexInto(IndexExpression e, int dest) {
    final mark = _top;
    final receiverReg = _compileOperand(e.realTarget);
    final indexReg = _compileOperand(e.index);
    _emitInvoke(dest, receiverReg, '[]', [indexReg]);
    _top = mark;
  }

  void _compileStringInterpolation(StringInterpolation e, int dest) {
    final mark = _top;
    var initialized = false;
    for (final element in e.elements) {
      final partReg = _alloc();
      switch (element) {
        case InterpolationString():
          _loadConstValue(partReg, element.value);
        case InterpolationExpression():
          _compileExprInto(element.expression, partReg);
          _emitInvoke(partReg, partReg, 'toString', const []);
      }
      if (!initialized) {
        _b.emitAB(Op.move, dest, partReg);
        initialized = true;
      } else {
        _emitInvoke(dest, dest, '+', [partReg]);
      }
    }
    if (!initialized) _loadConstValue(dest, '');
    _top = mark;
  }

  void _compileAdjacentStrings(AdjacentStrings e, int dest) {
    final mark = _top;
    var initialized = false;
    for (final string in e.strings) {
      final partReg = _alloc();
      _compileExprInto(string, partReg);
      if (!initialized) {
        _b.emitAB(Op.move, dest, partReg);
        initialized = true;
      } else {
        _emitInvoke(dest, dest, '+', [partReg]);
      }
    }
    _top = mark;
  }

  void _compileListLiteral(ListLiteral e, int dest) {
    _b.emitA(Op.listNew, dest);
    for (final element in e.elements) {
      _compileCollectionElement(element, dest, isMap: false);
    }
  }

  void _compileSetOrMapLiteral(SetOrMapLiteral e, int dest) {
    final isMap = e.staticType?.isDartCoreMap ?? e.elements.isEmpty;
    _b.emitA(isMap ? Op.mapNew : Op.setNew, dest);
    for (final element in e.elements) {
      _compileCollectionElement(element, dest, isMap: isMap);
    }
  }

  /// Adds one collection-literal element to the collection in [coll]. Handles
  /// plain values, map entries, spreads (`...xs`, `...?xs`), conditional
  /// elements (`if (c) x else y`), and loop elements (`for (e in xs) …`).
  void _compileCollectionElement(
    CollectionElement element,
    int coll, {
    required bool isMap,
  }) {
    final mark = _top;
    switch (element) {
      case MapLiteralEntry():
        final key = _compileOperand(element.key);
        final value = _compileOperand(element.value);
        _emitInvoke(null, coll, '[]=', [key, value]);
      case Expression():
        _emitInvoke(null, coll, 'add', [_compileOperand(element)]);
      case SpreadElement():
        final source = _compileOperand(element.expression);
        if (element.isNullAware) {
          // `...?xs`: add all only when the source is non-null.
          final nullReg = _alloc();
          _b.emitA(Op.loadNull, nullReg);
          final cond = _alloc();
          _b.emitABC(Op.ne, cond, source, nullReg);
          final skip = _b.newLabel();
          _b.emitBranch(Op.jz, cond, skip); // source == null: skip
          _emitInvoke(null, coll, 'addAll', [source]);
          _b.bind(skip);
        } else {
          _emitInvoke(null, coll, 'addAll', [source]);
        }
      case IfElement():
        final cond = _compileOperand(element.expression);
        final elseLabel = _b.newLabel();
        _b.emitBranch(Op.jz, cond, elseLabel);
        _top = mark;
        _compileCollectionElement(element.thenElement, coll, isMap: isMap);
        final elseElement = element.elseElement;
        if (elseElement != null) {
          final endLabel = _b.newLabel();
          _b.emitJmp(endLabel);
          _b.bind(elseLabel);
          _compileCollectionElement(elseElement, coll, isMap: isMap);
          _b.bind(endLabel);
        } else {
          _b.bind(elseLabel);
        }
      case ForElement():
        _compileForElement(element, coll, isMap: isMap);
      default:
        _unsupported(element, 'this collection element is not yet supported');
    }
    _top = mark;
  }

  /// Compiles a `for` element inside a collection literal, adding each iteration
  /// to [coll]. Supports `for (e in xs)` and C-style `for (init; cond; update)`.
  void _compileForElement(ForElement e, int coll, {required bool isMap}) {
    final parts = e.forLoopParts;
    final savedTop = _top;
    final savedScope = _scope;
    _scope = [];
    if (parts is ForEachParts) {
      final int loopReg;
      switch (parts) {
        case ForEachPartsWithDeclaration():
          final element = parts.loopVariable.declaredFragment?.element;
          if (element == null) {
            _unsupported(e, 'loop variable has no resolved element');
          }
          loopReg = _alloc();
          _locals[element] = loopReg;
          _scope.add(element);
        case ForEachPartsWithIdentifier():
          final reg = _locals[parts.identifier.element];
          if (reg == null) {
            _unsupported(e, 'for-in target must be a local variable');
          }
          loopReg = reg;
        default:
          _unsupported(e, 'this for-in form is not yet supported');
      }
      final iteratorReg = _alloc();
      final setup = _top;
      final iterableReg = _compileOperand(parts.iterable);
      _emitInvoke(iteratorReg, iterableReg, 'iterator', const []);
      _top = setup;
      final loopLabel = _b.newLabel();
      final endLabel = _b.newLabel();
      _b.bind(loopLabel);
      final hasNext = _alloc();
      _emitInvoke(hasNext, iteratorReg, 'moveNext', const []);
      _b.emitBranch(Op.jz, hasNext, endLabel);
      _top = setup;
      _emitInvoke(loopReg, iteratorReg, 'current', const []);
      _compileCollectionElement(e.body, coll, isMap: isMap);
      _b.emitJmp(loopLabel);
      _b.bind(endLabel);
    } else if (parts is ForParts) {
      if (parts is ForPartsWithDeclarations) {
        _compileVariableDeclarationList(parts.variables);
      } else if (parts is ForPartsWithExpression &&
          parts.initialization != null) {
        _compileExpressionForEffect(parts.initialization!);
      }
      final loopLabel = _b.newLabel();
      final endLabel = _b.newLabel();
      _b.bind(loopLabel);
      final condition = parts.condition;
      if (condition != null) {
        final condMark = _top;
        final cond = _compileOperand(condition);
        _b.emitBranch(Op.jz, cond, endLabel);
        _top = condMark;
      }
      _compileCollectionElement(e.body, coll, isMap: isMap);
      for (final updater in parts.updaters) {
        final uMark = _top;
        _compileExpressionForEffect(updater);
        _top = uMark;
      }
      _b.emitJmp(loopLabel);
      _b.bind(endLabel);
    } else {
      _unsupported(e, 'this for-element form is not yet supported');
    }
    for (final element in _scope) {
      _locals.remove(element);
    }
    _scope = savedScope;
    _top = savedTop;
  }

  void _compileIdentifierInto(SimpleIdentifier id, int dest) {
    final element = id.element;
    // An unqualified static field reference inside its own class.
    final staticGlobal = _staticGlobalFor(element);
    if (staticGlobal != null) {
      _b.emitABx(Op.loadGlobal, dest, staticGlobal);
      return;
    }
    final localReg = _locals[element];
    if (localReg != null) {
      if (_boxed.contains(element)) {
        _b.emitAB(Op.cellGet, dest, localReg);
      } else if (localReg != dest) {
        _b.emitAB(Op.move, dest, localReg);
      }
      return;
    }
    if (element is TopLevelFunctionElement) {
      final index = _functionIndices[element];
      if (index == null) {
        _unsupported(
          id,
          'function `${id.name}` is not in this compilation unit',
        );
      }
      _b.emitABx(Op.loadFunc, dest, index);
      return;
    }
    // Inside a method: an unqualified name may be an instance field (read from
    // `this`) or an instance member (getter/method reference, dispatched on
    // `this`).
    final enclosing = _enclosingClass;
    if (enclosing != null) {
      final slot = enclosing.fieldsByName[id.name];
      if (slot != null) {
        _b.emitABC(Op.loadField, dest, _thisReg, slot);
        return;
      }
      // A bare instance-method name used as a value is a tear-off bound to
      // `this` (e.g. passing `handleTap` as a callback); a getter is invoked.
      if (element is MethodElement && !element.isStatic) {
        final arity = _tearOffArity(element);
        if (arity == null) {
          _unsupported(
            id,
            'tearing off a method with optional/named parameters is not yet '
            'supported',
          );
        }
        _emitMethodTearOff(_thisReg, arity, id.name, dest);
        return;
      }
      _emitInvoke(dest, _thisReg, id.name, const []);
      return;
    }
    // Inside an extension member, an unqualified member name dispatches on the
    // extended receiver (`this`), which has no field layout. An extension type's
    // representation name resolves to `this` itself (the erased value).
    if (_isExtension) {
      if (id.name == _extensionRepName) {
        if (dest != _thisReg) _b.emitAB(Op.move, dest, _thisReg);
      } else {
        _emitInvoke(dest, _thisReg, id.name, const []);
      }
      return;
    }
    _unsupported(
      id,
      'identifier `${id.name}` refers to something not yet supported',
      correction:
          'only locals, parameters, and top-level functions are '
          'supported in this subset',
    );
  }

  /// The member element named by a property access node (`obj.member`), or
  /// `null` for a node shape that carries none.
  Element? _propertyElement(AstNode node) {
    if (node is PropertyAccess) return node.propertyName.element;
    if (node is PrefixedIdentifier) return node.identifier.element;
    return null;
  }

  /// Returns the fixed positional arity of [method] if it can be torn off — all
  /// parameters required and positional — or `null` if it uses optional/named
  /// parameters (whose tear-off would need default handling).
  int? _tearOffArity(ExecutableElement method) {
    for (final p in method.formalParameters) {
      if (!p.isRequiredPositional) return null;
    }
    return method.formalParameters.length;
  }

  /// Synthesizes a bound-method tear-off: a fresh closure of [arity] parameters
  /// that captures the receiver (currently in [receiverReg]) and forwards to
  /// `receiver.selector(args)`. Reuses the ordinary closure machinery, so the
  /// result is a first-class value that marshals to a host callback like any
  /// other closure.
  void _emitMethodTearOff(
    int receiverReg,
    int arity,
    String selector,
    int dest,
  ) {
    final protoIndex = _sink.reserve();
    // Forwarder body: params occupy R[0..arity-1]; upvalue 0 is the receiver
    // cell. Lay out [receiver, arg0…] contiguously at `base` for invoke.dyn.
    final fb = BytecodeBuilder();
    final base = arity;
    fb
      ..emitABx(Op.upvalGet, base, 0)
      ..emitAB(Op.cellGet, base, base); // R[base] = receiver
    for (var i = 0; i < arity; i++) {
      fb.emitAB(Op.move, base + 1 + i, i); // copy arg i after the receiver
    }
    fb
      ..emitABx(Op.invokeDyn, base, _callSite(selector, arity))
      ..emitA(Op.ret, base);

    final mark = _top;
    final cellReg = _alloc();
    _b
      ..emitAB(Op.move, cellReg, receiverReg)
      ..emitA(Op.cellNew, cellReg); // box the receiver for capture
    _sink.place(
      protoIndex,
      fb.toProto(
        name: '$selector\$tearoff',
        paramCount: arity,
        registerCount: base + 1 + arity,
        captures: [cellReg],
      ),
    );
    _b.emitABx(Op.closureNew, dest, protoIndex);
    _top = mark;
  }

  void _compilePrefixInto(PrefixExpression e, int dest) {
    final opType = e.operator.type;
    if (_isIncDec(opType)) {
      // `++x` / `--x`: update the variable, then yield its new value.
      final mark = _top;
      final reg = _incDecInPlace(e.operand, opType, e);
      if (dest != reg) _b.emitAB(Op.move, dest, reg);
      _top = mark; // reclaim any temp a boxed target used
      return;
    }
    final mark = _top;
    final operand = _compileOperand(e.operand);
    final type = e.operand.staticType;
    switch (opType) {
      case TokenType.BANG:
        _b.emitAB(Op.not, dest, operand);
      case TokenType.MINUS:
        if (_isInt(type)) {
          _b.emitAB(Op.negInt, dest, operand);
        } else if (_isDouble(type)) {
          _b.emitAB(Op.negDouble, dest, operand);
        } else {
          _emitInvoke(dest, operand, 'unary-', const []);
        }
      case TokenType.TILDE:
        _emitInvoke(dest, operand, '~', const []);
      default:
        _unsupported(
          e,
          'prefix operator `${e.operator.lexeme}` is not '
          'supported',
        );
    }
    _top = mark;
  }

  void _compilePostfixInto(PostfixExpression e, int dest) {
    // `x!` — the null-assertion operator. Types are checked statically, so this
    // lowers to the value itself.
    if (e.operator.type == TokenType.BANG) {
      _compileExprInto(e.operand, dest);
      return;
    }
    if (!_isIncDec(e.operator.type)) {
      _unsupported(
        e,
        'postfix operator `${e.operator.lexeme}` is not '
        'supported',
      );
    }
    final target = e.operand;
    if (target is! SimpleIdentifier) {
      _unsupported(e, 'increment target must be a variable');
    }
    final element = target.element;
    final reg = _locals[element];
    if (reg == null) {
      _unsupported(e, 'increment target must be a local or parameter');
    }
    if (_boxed.contains(element)) {
      // `x++` on a captured variable: yield the old value, store new + step.
      final mark = _top;
      _b.emitAB(Op.cellGet, dest, reg); // dest = old value
      final v = _alloc();
      _b.emitAB(Op.cellGet, v, reg);
      _incReg(v, e.operator.type, _variableType(target), e);
      _b.emitAB(Op.cellSet, reg, v);
      _top = mark;
      return;
    }
    // `x++`: yield the old value first, then update the variable.
    if (dest != reg) _b.emitAB(Op.move, dest, reg);
    _incReg(reg, e.operator.type, _variableType(target), e);
  }

  /// Applies `++`/`--` to the local behind [target] in place. Returns the
  /// register holding its new value.
  int _incDecInPlace(Expression target, TokenType op, AstNode node) {
    if (target is! SimpleIdentifier) {
      _unsupported(node, 'increment target must be a variable');
    }
    final element = target.element;
    final reg = _locals[element];
    if (reg == null) {
      _unsupported(node, 'increment target must be a local or parameter');
    }
    if (_boxed.contains(element)) {
      final v = _alloc();
      _b.emitAB(Op.cellGet, v, reg);
      _incReg(v, op, _variableType(target), node);
      _b.emitAB(Op.cellSet, reg, v);
      return v; // holds the new value
    }
    _incReg(reg, op, _variableType(target), node);
    return reg;
  }

  void _incReg(int reg, TokenType op, DartType? type, AstNode node) {
    final increment = op == TokenType.PLUS_PLUS;
    final mark = _top;
    final one = _alloc();
    if (_isInt(type)) {
      _b.emitLoadInt(one, 1);
      _b.emitABC(increment ? Op.addInt : Op.subInt, reg, reg, one);
    } else if (_isDouble(type)) {
      _loadConstValue(one, 1.0);
      _b.emitABC(increment ? Op.addDouble : Op.subDouble, reg, reg, one);
    } else {
      _unsupported(
        node,
        'increment/decrement requires an int or double '
        'variable',
      );
    }
    _top = mark;
  }

  bool _isIncDec(TokenType t) =>
      t == TokenType.PLUS_PLUS || t == TokenType.MINUS_MINUS;

  void _compileBinaryInto(BinaryExpression e, int dest) {
    final opType = e.operator.type;
    if (opType == TokenType.AMPERSAND_AMPERSAND ||
        opType == TokenType.BAR_BAR) {
      _compileLogicalInto(e, dest);
      return;
    }
    if (opType == TokenType.QUESTION_QUESTION) {
      _compileIfNull(e.leftOperand, e.rightOperand, dest);
      return;
    }
    final mark = _top;
    final l = _compileOperand(e.leftOperand);
    final r = _compileOperand(e.rightOperand);
    _emitBinaryOp(
      opType,
      dest,
      l,
      r,
      e.leftOperand.staticType,
      e.rightOperand.staticType,
      e,
    );
    _top = mark;
  }

  void _compileLogicalInto(BinaryExpression e, int dest) {
    // Short-circuit: `a && b` keeps a's (false) value when a is false;
    // `a || b` keeps a's (true) value when a is true.
    _compileExprInto(e.leftOperand, dest);
    final end = _b.newLabel();
    if (e.operator.type == TokenType.AMPERSAND_AMPERSAND) {
      _b.emitBranch(Op.jz, dest, end);
    } else {
      _b.emitBranch(Op.jnz, dest, end);
    }
    _compileExprInto(e.rightOperand, dest);
    _b.bind(end);
  }

  /// `left ?? right`: yields `left` unless it is null, else `right`.
  void _compileIfNull(Expression left, Expression right, int dest) {
    _compileExprInto(left, dest);
    final mark = _top;
    final nullReg = _alloc();
    _b.emitA(Op.loadNull, nullReg);
    final cond = _alloc();
    _b.emitABC(Op.ne, cond, dest, nullReg); // dest != null
    final end = _b.newLabel();
    _b.emitBranch(Op.jnz, cond, end); // non-null: keep dest
    _top = mark;
    _compileExprInto(right, dest);
    _b.bind(end);
  }

  /// Lowers `target..a()..b = v` — evaluate the receiver once, apply each
  /// cascade section to it, and yield the receiver.
  void _compileCascadeInto(CascadeExpression e, int dest) {
    final mark = _top;
    final recv = _alloc();
    _compileExprInto(e.target, recv);
    final recvType = e.target.staticType;
    for (final section in e.cascadeSections) {
      _compileCascadeSection(section, recv, recvType);
    }
    if (dest != recv) _b.emitAB(Op.move, dest, recv);
    _top = mark;
  }

  void _compileCascadeSection(
    Expression section,
    int recv,
    DartType? recvType,
  ) {
    final mark = _top;
    switch (section) {
      case MethodInvocation():
        final argRegs = [
          for (final a in section.argumentList.arguments)
            _compileOperand(a.argumentExpression),
        ];
        _emitInvoke(null, recv, section.methodName.name, argRegs);
      case AssignmentExpression(leftHandSide: final lhs)
          when section.operator.type == TokenType.EQ:
        if (lhs is PropertyAccess) {
          final name = lhs.propertyName.name;
          final value = _compileOperand(section.rightHandSide);
          final slot = _fieldSlotOf(recvType, name);
          if (slot != null) {
            _b.emitABC(Op.storeField, recv, slot, value);
          } else {
            _emitInvoke(null, recv, '$name=', [value]);
          }
        } else if (lhs is IndexExpression) {
          final index = _compileOperand(lhs.index);
          final value = _compileOperand(section.rightHandSide);
          _emitInvoke(null, recv, '[]=', [index, value]);
        } else {
          _unsupported(section, 'this cascade section is not yet supported');
        }
      case PropertyAccess():
        // `..getter` — evaluated for effect, result discarded.
        _emitInvoke(null, recv, section.propertyName.name, const []);
      default:
        _unsupported(section, 'this cascade section is not yet supported');
    }
    _top = mark;
  }

  /// Lowers a `switch` expression to a comparison chain that writes the matching
  /// arm's value into [dest]. Supports constant patterns and the `_` wildcard;
  /// the analyzer guarantees exhaustiveness.
  void _compileSwitchExpressionInto(SwitchExpression e, int dest) {
    final mark = _top;
    final scrutinee = _alloc();
    _compileExprInto(e.expression, scrutinee);
    final caseMark = _top;
    final end = _b.newLabel();
    for (final c in e.cases) {
      _top = caseMark;
      final savedLocals = Map<Element, int>.of(_locals);
      final savedScope = _scope;
      _scope = [];
      final next = _b.newLabel();
      _matchGuarded(c.guardedPattern, scrutinee, next);
      _compileExprInto(c.expression, dest);
      _b.emitJmp(end);
      _b.bind(next);
      _locals
        ..clear()
        ..addAll(savedLocals);
      _scope = savedScope;
    }
    // Exhaustiveness is analyzer-checked; throw if no arm matched at runtime.
    _throwMatchError();
    _b.bind(end);
    _top = mark;
  }

  /// Matches [gp]'s pattern against [valueReg], then evaluates its `when` guard
  /// (if any); either failing jumps to [fail].
  void _matchGuarded(GuardedPattern gp, int valueReg, Label fail) {
    _matchPattern(gp.pattern, valueReg, fail);
    final when = gp.whenClause;
    if (when != null) {
      final mark = _top;
      final cond = _compileOperand(when.expression);
      _b.emitBranch(Op.jz, cond, fail);
      _top = mark;
    }
  }

  void _compileConditionalInto(ConditionalExpression e, int dest) {
    // A constant condition selects one arm at compile time.
    final constCond = _constFold(e.condition);
    if (constCond is bool) {
      _compileExprInto(constCond ? e.thenExpression : e.elseExpression, dest);
      return;
    }

    final mark = _top;
    final cond = _compileOperand(e.condition);
    final elseLabel = _b.newLabel();
    final endLabel = _b.newLabel();
    _b.emitBranch(Op.jz, cond, elseLabel);
    _top = mark;
    _compileExprInto(e.thenExpression, dest);
    _b.emitJmp(endLabel);
    _b.bind(elseLabel);
    _compileExprInto(e.elseExpression, dest);
    _b.bind(endLabel);
  }

  void _compileAssignment(AssignmentExpression e, int? dest) {
    final target = e.leftHandSide;
    final opType = e.operator.type;

    // Static-field assignment: `C.x = v` / `x op= v` writes a module global. The
    // write target's element is on `writeElement` (a setter); the read/write
    // target's on `readElement` — both resolve back to the field.
    final staticGlobal = _staticGlobalFor(e.writeElement ?? e.readElement);
    if (staticGlobal != null) {
      _compileStaticFieldAssign(e, staticGlobal, dest);
      return;
    }

    // Index assignment: `xs[i] = v`, `xs[i] op= v`, `xs[i] ??= v` (evaluates to
    // the stored value). Receiver and index are evaluated once.
    if (target is IndexExpression) {
      final mark = _top;
      final receiver = _compileOperand(target.realTarget);
      final index = _compileOperand(target.index);
      final int valueReg;
      if (opType == TokenType.EQ) {
        valueReg = _compileOperand(e.rightHandSide);
      } else {
        final current = _alloc();
        _emitInvoke(current, receiver, '[]', [index]);
        valueReg = _alloc();
        if (opType == TokenType.QUESTION_QUESTION_EQ) {
          _b.emitAB(Op.move, valueReg, current);
          final nullReg = _alloc();
          _b.emitA(Op.loadNull, nullReg);
          final cond = _alloc();
          _b.emitABC(Op.ne, cond, current, nullReg);
          final end = _b.newLabel();
          _b.emitBranch(Op.jnz, cond, end); // current != null: keep it
          _compileExprInto(e.rightHandSide, valueReg);
          _b.bind(end);
        } else {
          final rhs = _compileOperand(e.rightHandSide);
          _emitBinaryOp(
            _compoundOperator(e),
            valueReg,
            current,
            rhs,
            target.staticType,
            e.rightHandSide.staticType,
            e,
          );
        }
      }
      _emitInvoke(null, receiver, '[]=', [index, valueReg]);
      if (dest != null && dest != valueReg) _b.emitAB(Op.move, dest, valueReg);
      _top = mark;
      return;
    }

    // Field assignment: `receiver.field = v`.
    if (target is PropertyAccess || target is PrefixedIdentifier) {
      _compileFieldAssign(e, target, dest);
      return;
    }

    if (target is! SimpleIdentifier) {
      _unsupported(e, 'assignment target is not yet supported');
    }
    final reg = _locals[target.element];
    if (reg == null) {
      // An unqualified field assignment inside a method (`x = v`).
      final slot = _enclosingClass?.fieldsByName[target.name];
      if (slot != null && opType == TokenType.EQ) {
        final mark = _top;
        final value = _compileOperand(e.rightHandSide);
        _b.emitABC(Op.storeField, _thisReg, slot, value);
        if (dest != null) _b.emitABC(Op.loadField, dest, _thisReg, slot);
        _top = mark;
        return;
      }
      _unsupported(
        e,
        'assignment to `${target.name}` is not supported',
        correction:
            'only assignment to locals, parameters, and fields is '
            'supported',
      );
    }

    // A captured variable lives in a cell; write through it so the closure and
    // the enclosing scope stay in sync.
    if (_boxed.contains(target.element)) {
      _compileBoxedAssign(e, target, reg, opType, dest);
      return;
    }

    if (opType == TokenType.EQ) {
      _compileExprInto(e.rightHandSide, reg);
    } else if (opType == TokenType.QUESTION_QUESTION_EQ) {
      // `reg ??= rhs`: assign only when reg is currently null.
      final mark = _top;
      final nullReg = _alloc();
      _b.emitA(Op.loadNull, nullReg);
      final cond = _alloc();
      _b.emitABC(Op.ne, cond, reg, nullReg);
      final end = _b.newLabel();
      _b.emitBranch(Op.jnz, cond, end); // reg != null: skip
      _top = mark;
      _compileExprInto(e.rightHandSide, reg);
      _b.bind(end);
    } else {
      final mark = _top;
      final rhs = _compileOperand(e.rightHandSide);
      _emitBinaryOp(
        _compoundOperator(e),
        reg,
        reg,
        rhs,
        _variableType(target),
        e.rightHandSide.staticType,
        e,
      );
      _top = mark;
    }
    if (dest != null && dest != reg) _b.emitAB(Op.move, dest, reg);
  }

  /// Assigns to a captured (boxed) local through its cell. Handles `=`, `??=`,
  /// and compound operators; the assignment expression evaluates to the stored
  /// value, delivered to [dest] when non-null.
  void _compileBoxedAssign(
    AssignmentExpression e,
    SimpleIdentifier target,
    int cellReg,
    TokenType opType,
    int? dest,
  ) {
    final mark = _top;
    final value = _alloc();
    if (opType == TokenType.EQ) {
      _compileExprInto(e.rightHandSide, value);
    } else if (opType == TokenType.QUESTION_QUESTION_EQ) {
      _b.emitAB(Op.cellGet, value, cellReg); // value = current
      final nullReg = _alloc();
      _b.emitA(Op.loadNull, nullReg);
      final cond = _alloc();
      _b.emitABC(Op.ne, cond, value, nullReg);
      final end = _b.newLabel();
      _b.emitBranch(Op.jnz, cond, end); // current != null: keep it
      _compileExprInto(e.rightHandSide, value); // else value = rhs
      _b.bind(end);
    } else {
      final cur = _alloc();
      _b.emitAB(Op.cellGet, cur, cellReg);
      final rhs = _compileOperand(e.rightHandSide);
      _emitBinaryOp(
        _compoundOperator(e),
        value,
        cur,
        rhs,
        _variableType(target),
        e.rightHandSide.staticType,
        e,
      );
    }
    _b.emitAB(Op.cellSet, cellReg, value);
    if (dest != null) _b.emitAB(Op.move, dest, value);
    _top = mark;
  }

  void _compileFieldAssign(
    AssignmentExpression e,
    Expression target,
    int? dest,
  ) {
    final Expression receiver;
    final String name;
    switch (target) {
      case PropertyAccess():
        receiver = target.realTarget;
        name = target.propertyName.name;
      case PrefixedIdentifier():
        receiver = target.prefix;
        name = target.identifier.name;
      default:
        _unsupported(e, 'assignment target is not supported');
    }
    final opType = e.operator.type;
    final mark = _top;
    final receiverReg = _compileOperand(receiver);
    final slot = _fieldSlotOf(receiver.staticType, name);

    // Reads a field: a direct slot when statically known, else a getter.
    void loadCurrent(int into) {
      if (slot != null) {
        _b.emitABC(Op.loadField, into, receiverReg, slot);
      } else {
        _emitInvoke(into, receiverReg, name, const []);
      }
    }

    final int valueReg;
    if (opType == TokenType.EQ) {
      valueReg = _compileOperand(e.rightHandSide);
    } else if (opType == TokenType.QUESTION_QUESTION_EQ) {
      valueReg = _alloc();
      loadCurrent(valueReg);
      final nullReg = _alloc();
      _b.emitA(Op.loadNull, nullReg);
      final cond = _alloc();
      _b.emitABC(Op.ne, cond, valueReg, nullReg);
      final end = _b.newLabel();
      _b.emitBranch(Op.jnz, cond, end); // current != null: keep it
      _compileExprInto(e.rightHandSide, valueReg);
      _b.bind(end);
    } else {
      final current = _alloc();
      loadCurrent(current);
      valueReg = _alloc();
      final rhs = _compileOperand(e.rightHandSide);
      _emitBinaryOp(
        _compoundOperator(e),
        valueReg,
        current,
        rhs,
        e.readType ?? target.staticType,
        e.rightHandSide.staticType,
        e,
      );
    }

    if (slot != null) {
      _b.emitABC(Op.storeField, receiverReg, slot, valueReg);
    } else {
      _emitInvoke(null, receiverReg, '$name=', [valueReg]);
    }
    if (dest != null && dest != valueReg) _b.emitAB(Op.move, dest, valueReg);
    _top = mark;
  }

  void _compileInvocationInto(MethodInvocation e, int dest) {
    final args = e.argumentList.arguments;

    // `super.method(args)`: statically dispatch to the superclass's method
    // (not the runtime override), passing `this` as the receiver.
    if (e.realTarget is SuperExpression) {
      final superIndex = _methodIndices[e.methodName.element];
      if (superIndex == null) {
        _unsupported(e, 'super method `${e.methodName.name}` not found');
      }
      final params =
          (e.methodName.element! as ExecutableElement).formalParameters;
      final mark = _top;
      final callBase = _alloc();
      _alloc(); // callBase+1 = this
      for (var i = 0; i < params.length; i++) {
        _alloc();
      }
      _b
        ..emitABx(Op.loadFunc, callBase, superIndex)
        ..emitAB(Op.move, callBase + 1, _thisReg);
      _emitArgsInParamOrder(callBase + 2, params, args);
      _b.emitABC(Op.call, callBase, 0, params.length + 1);
      if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
      _top = mark;
      return;
    }

    // Static method call: `Type.method(args)`. A method declared in this unit
    // (`C.f()`) is a direct call to its function; a host static (`int.parse`)
    // dispatches to a host global named `Type.method`.
    final staticTarget = e.realTarget;
    if (staticTarget is SimpleIdentifier &&
        staticTarget.element is InterfaceElement) {
      final staticFn = _functionIndices[e.methodName.element];
      if (staticFn != null) {
        final params =
            (e.methodName.element! as ExecutableElement).formalParameters;
        _compileStaticCall(staticFn, params, args, dest);
        return;
      }
      final selector = '${staticTarget.name}.${e.methodName.name}';
      _emitHostCall(dest, selector, args);
      return;
    }

    // Extension method: `receiver.extMethod(args)` resolves statically to the
    // extension's function, invoked with the receiver as its first argument.
    final extIndex = _functionIndices[e.methodName.element];
    if (e.realTarget != null && extIndex != null) {
      final params =
          (e.methodName.element! as ExecutableElement).formalParameters;
      final mark = _top;
      final callBase = _alloc();
      _alloc(); // receiver at callBase + 1
      for (var i = 0; i < params.length; i++) {
        _alloc();
      }
      _b.emitABx(Op.loadFunc, callBase, extIndex);
      _compileExprInto(e.realTarget!, callBase + 1);
      _emitArgsInParamOrder(callBase + 2, params, args);
      _b.emitABC(Op.call, callBase, 0, 1 + params.length);
      if (dest != callBase) _b.emitAB(Op.move, dest, callBase);
      _top = mark;
      return;
    }

    // Instance method: `receiver.method(args)`, possibly null-aware.
    if (e.realTarget != null) {
      final method = e.methodName.element;
      // Named/optional arguments on a method declared in this unit reorder into
      // parameter slots, with defaults filled by the callee prologue.
      if (_hasNamedOrOptional(args, method)) {
        _compileNamedInstanceCall(e, method! as MethodElement, dest);
        return;
      }
      final mark = _top;
      final receiverReg = _compileOperand(e.realTarget!);
      // A host method takes positional arguments; reorder any named ones into
      // the resolved parameter order.
      final argRegs = args.any((a) => a is NamedArgument)
          ? _hostArgsInParamOrder(
              (method! as ExecutableElement).formalParameters,
              args,
            )
          : [for (final a in args) _compileOperand(a.argumentExpression)];
      final selector = e.methodName.name;
      if (e.isNullAware) {
        _compileNullAwareChain(
          receiverReg,
          dest,
          () => _emitInvoke(dest, receiverReg, selector, argRegs),
        );
      } else {
        _emitInvoke(dest, receiverReg, selector, argRegs);
      }
      _top = mark;
      return;
    }

    final callee = e.methodName.element;

    // A unit function called unqualified — a top-level function or an
    // (unqualified) static method — is a direct call. Named and optional
    // arguments are reordered into parameter slots, defaults filled by the
    // callee prologue.
    final directIndex = _functionIndices[callee];
    if (directIndex != null && callee is ExecutableElement) {
      _compileStaticCall(directIndex, callee.formalParameters, args, dest);
      return;
    }

    // External function (e.g. `print`): dispatch to a host global. Arguments
    // occupy R[base .. base+argCount-1] with no receiver slot.
    if (callee is TopLevelFunctionElement) {
      _rejectNamedArgs(args, 'host functions');
      final mark = _top;
      final base = _alloc();
      for (var i = 1; i < args.length; i++) {
        _alloc(); // reserve base+1 .. base+argCount-1 contiguously
      }
      for (var i = 0; i < args.length; i++) {
        _compileExprInto(args[i].argumentExpression, base + i);
      }
      _b.emitABx(
        Op.invokeStatic,
        base,
        _callSite(e.methodName.name, args.length),
      );
      if (dest != base) _b.emitAB(Op.move, dest, base);
      _top = mark;
      return;
    }

    // A local variable or parameter holding a callable: `f(args)`.
    if (callee != null && _locals.containsKey(callee)) {
      _compileValueCall(e.methodName, args, dest);
      return;
    }

    // Unqualified instance method call inside a class: dispatch on `this`.
    if (_enclosingClass != null) {
      final method = e.methodName.element;
      if (_hasNamedOrOptional(args, method)) {
        final params = (method! as MethodElement).formalParameters;
        final mark = _top;
        final base = _alloc();
        for (var i = 0; i < params.length; i++) {
          _alloc();
        }
        _b.emitAB(Op.move, base, _thisReg);
        _emitArgsInParamOrder(base + 1, params, args);
        _b.emitABx(
          Op.invokeDyn,
          base,
          _callSite(e.methodName.name, params.length),
        );
        if (dest != base) _b.emitAB(Op.move, dest, base);
        _top = mark;
        return;
      }
      _rejectNamedArgs(args, 'instance methods');
      final mark = _top;
      final argRegs = [
        for (final a in args) _compileOperand(a.argumentExpression),
      ];
      _emitInvoke(dest, _thisReg, e.methodName.name, argRegs);
      _top = mark;
      return;
    }

    _unsupported(e, 'this call form is not yet supported');
  }

  /// Rejects named arguments in [args] for a call site ([where]) that does not
  /// yet support them, with a clear diagnostic rather than a mis-lowering.
  void _rejectNamedArgs(List<Argument> args, String where) {
    for (final arg in args) {
      if (arg is NamedArgument) {
        _unsupported(arg, 'named arguments on $where are not yet supported');
      }
    }
  }

  // --- Typed operator emission ---

  void _emitBinaryOp(
    TokenType op,
    int dest,
    int l,
    int r,
    DartType? lt,
    DartType? rt,
    AstNode node,
  ) {
    switch (op) {
      case TokenType.PLUS:
        _numeric(dest, l, r, lt, rt, Op.addInt, Op.addDouble, '+');
      case TokenType.MINUS:
        _numeric(dest, l, r, lt, rt, Op.subInt, Op.subDouble, '-');
      case TokenType.STAR:
        _numeric(dest, l, r, lt, rt, Op.mulInt, Op.mulDouble, '*');
      case TokenType.PERCENT:
        _numeric(dest, l, r, lt, rt, Op.modInt, Op.modDouble, '%');
      case TokenType.SLASH:
        // `/` is always double-valued in Dart.
        if (_isNumeric(lt) && _isNumeric(rt)) {
          _b.emitABC(
            Op.divDouble,
            dest,
            _widenIfInt(l, lt),
            _widenIfInt(r, rt),
          );
        } else {
          _emitInvoke(dest, l, '/', [r]);
        }
      case TokenType.TILDE_SLASH:
        if (_isInt(lt) && _isInt(rt)) {
          _b.emitABC(Op.divInt, dest, l, r);
        } else {
          _emitInvoke(dest, l, '~/', [r]);
        }
      case TokenType.LT:
        _compare(dest, l, r, lt, rt, Op.ltInt, Op.ltDouble, '<');
      case TokenType.LT_EQ:
        _compare(dest, l, r, lt, rt, Op.leInt, Op.leDouble, '<=');
      case TokenType.GT:
        _compare(dest, l, r, lt, rt, Op.gtInt, Op.gtDouble, '>');
      case TokenType.GT_EQ:
        _compare(dest, l, r, lt, rt, Op.geInt, Op.geDouble, '>=');
      case TokenType.EQ_EQ:
        if (_isUserClass(lt)) {
          // A user class may override `==`; dispatch dynamically (an instance
          // without an override falls back to identity in the runtime).
          _emitInvoke(dest, l, '==', [r]);
        } else if (_isInt(lt) && _isInt(rt)) {
          _b.emitABC(Op.eqInt, dest, l, r);
        } else {
          _b.emitABC(Op.eq, dest, l, r);
        }
      case TokenType.BANG_EQ:
        if (_isUserClass(lt)) {
          _emitInvoke(dest, l, '==', [r]);
          _b.emitAB(Op.not, dest, dest);
        } else if (_isInt(lt) && _isInt(rt)) {
          _b.emitABC(Op.neInt, dest, l, r);
        } else {
          _b.emitABC(Op.ne, dest, l, r);
        }
      default:
        // Bitwise/shift and any operator on a non-primitive: dispatch to the
        // host as a method named by the operator (`&`, `|`, `<<`, …).
        _emitInvoke(dest, l, op.lexeme, [r]);
    }
  }

  /// Emits an arithmetic op: the typed opcode for concrete `int`/`double`, else
  /// a dynamic dispatch to [selector] (covering `num`-typed and `String`
  /// operands).
  void _numeric(
    int dest,
    int l,
    int r,
    DartType? lt,
    DartType? rt,
    Op intOp,
    Op doubleOp,
    String selector,
  ) {
    if (_isInt(lt) && _isInt(rt)) {
      _b.emitABC(intOp, dest, l, r);
    } else if (_isNumeric(lt) && _isNumeric(rt)) {
      _b.emitABC(doubleOp, dest, _widenIfInt(l, lt), _widenIfInt(r, rt));
    } else {
      _emitInvoke(dest, l, selector, [r]);
    }
  }

  void _compare(
    int dest,
    int l,
    int r,
    DartType? lt,
    DartType? rt,
    Op intOp,
    Op doubleOp,
    String selector,
  ) {
    if (_isInt(lt) && _isInt(rt)) {
      _b.emitABC(intOp, dest, l, r);
    } else if (_isNumeric(lt) && _isNumeric(rt)) {
      _b.emitABC(doubleOp, dest, _widenIfInt(l, lt), _widenIfInt(r, rt));
    } else {
      _emitInvoke(dest, l, selector, [r]);
    }
  }

  int _widenIfInt(int reg, DartType? type) {
    if (_isInt(type)) {
      final widened = _alloc();
      _b.emitAB(Op.i2d, widened, reg);
      return widened;
    }
    return reg;
  }

  // --- Helpers ---

  void _loadInt(int dest, int value) {
    if (value >= minSbx && value <= maxSbx) {
      _b.emitLoadInt(dest, value);
    } else {
      _b.emitABx(Op.loadConst, dest, _constants.add(value));
    }
  }

  void _loadConstValue(int dest, Object? value) {
    _b.emitABx(Op.loadConst, dest, _constants.add(value));
  }

  /// Sentinel distinguishing "not a compile-time constant" from a constant that
  /// happens to be `null`.
  static const Object _notConst = Object();

  /// Emits [value] with the tightest load opcode for its runtime type.
  void _emitConst(int dest, Object? value) {
    if (value is int) {
      _loadInt(dest, value);
    } else if (value is bool) {
      _b.emitA(value ? Op.loadTrue : Op.loadFalse, dest);
    } else if (value == null) {
      _b.emitA(Op.loadNull, dest);
    } else {
      _loadConstValue(dest, value); // double or String
    }
  }

  /// Attempts to evaluate [e] to a compile-time constant, returning [_notConst]
  /// when it is not foldable. Folding is a pure optimization: every operator is
  /// evaluated with the *same* Dart operator the interpreter would apply at
  /// runtime, so a folded result is bit-identical to executing the opcodes.
  /// Anything that would throw at runtime (e.g. `~/ 0`) is left unfolded so the
  /// interpreter reproduces the fault. See `spec/dart-subset.md`.
  Object? _constFold(Expression e) {
    switch (e) {
      case IntegerLiteral():
        return e.value ?? _notConst; // out-of-range stays a diagnostic
      case DoubleLiteral():
        return e.value;
      case BooleanLiteral():
        return e.value;
      case SimpleStringLiteral():
        return e.value;
      case NullLiteral():
        return null;
      case ParenthesizedExpression():
        return _constFold(e.expression);
      case PrefixExpression():
        final v = _constFold(e.operand);
        if (identical(v, _notConst)) return _notConst;
        return _foldPrefix(e.operator.type, v);
      case BinaryExpression():
        final l = _constFold(e.leftOperand);
        if (identical(l, _notConst)) return _notConst;
        final r = _constFold(e.rightOperand);
        if (identical(r, _notConst)) return _notConst;
        return _foldBinary(e.operator.type, l, r);
      default:
        return _notConst;
    }
  }

  Object? _foldPrefix(TokenType op, Object? v) {
    try {
      switch (op) {
        case TokenType.MINUS:
          if (v is num) return -v;
        case TokenType.BANG:
          if (v is bool) return !v;
        case TokenType.TILDE:
          if (v is int) return ~v;
        default:
          break;
      }
    } catch (_) {
      // Fall through to _notConst on any arithmetic fault.
    }
    return _notConst;
  }

  Object? _foldBinary(TokenType op, Object? l, Object? r) {
    try {
      if (l is num && r is num) {
        switch (op) {
          case TokenType.PLUS:
            return l + r;
          case TokenType.MINUS:
            return l - r;
          case TokenType.STAR:
            return l * r;
          case TokenType.SLASH:
            return l / r; // always double, matches div.d (∞ on /0, no throw)
          case TokenType.TILDE_SLASH:
            return r == 0 ? _notConst : l ~/ r;
          case TokenType.PERCENT:
            return r == 0 ? _notConst : l % r;
          case TokenType.LT:
            return l < r;
          case TokenType.LT_EQ:
            return l <= r;
          case TokenType.GT:
            return l > r;
          case TokenType.GT_EQ:
            return l >= r;
          case TokenType.EQ_EQ:
            return l == r;
          case TokenType.BANG_EQ:
            return l != r;
          default:
            break;
        }
        if (l is int && r is int) {
          switch (op) {
            case TokenType.AMPERSAND:
              return l & r;
            case TokenType.BAR:
              return l | r;
            case TokenType.CARET:
              return l ^ r;
            case TokenType.LT_LT:
              return (r < 0 || r > 63) ? _notConst : l << r;
            case TokenType.GT_GT:
              return r < 0 ? _notConst : l >> r;
            default:
              break;
          }
        }
      } else if (l is bool && r is bool) {
        switch (op) {
          case TokenType.AMPERSAND_AMPERSAND:
            return l && r;
          case TokenType.BAR_BAR:
            return l || r;
          case TokenType.EQ_EQ:
            return l == r;
          case TokenType.BANG_EQ:
            return l != r;
          default:
            break;
        }
      } else if (l is String && r is String) {
        switch (op) {
          case TokenType.PLUS:
            return l + r;
          case TokenType.EQ_EQ:
            return l == r;
          case TokenType.BANG_EQ:
            return l != r;
          default:
            break;
        }
      }
    } catch (_) {
      // Any fault (overflow-free in Dart, but be defensive) leaves it unfolded.
    }
    return _notConst;
  }

  /// The runtime type spec for an `is`/`as` check: the base type name with a
  /// trailing `?` for nullability, generics erased (`List<int>?` → `List?`).
  String _typeSpec(DartType? t) {
    final display = t?.getDisplayString() ?? 'Object';
    final nullable = display.endsWith('?');
    var base = nullable ? display.substring(0, display.length - 1) : display;
    final lt = base.indexOf('<');
    if (lt >= 0) base = base.substring(0, lt);
    return nullable ? '$base?' : base;
  }

  bool _isUserClass(DartType? t) =>
      t != null && _classLayouts.containsKey(t.element);
  bool _isInt(DartType? t) => t != null && t.isDartCoreInt;
  bool _isDouble(DartType? t) => t != null && t.isDartCoreDouble;
  bool _isNumeric(DartType? t) => _isInt(t) || _isDouble(t);

  /// The type of an assignable target. The analyzer leaves `staticType` null on
  /// an identifier in a write or read-write position, so the type is taken from
  /// the resolved variable element instead.
  DartType? _variableType(Expression target) {
    if (target is SimpleIdentifier) {
      final element = target.element;
      if (element is VariableElement) return element.type;
    }
    return target.staticType;
  }

  TokenType _compoundOperator(AssignmentExpression e) {
    switch (e.operator.type) {
      case TokenType.PLUS_EQ:
        return TokenType.PLUS;
      case TokenType.MINUS_EQ:
        return TokenType.MINUS;
      case TokenType.STAR_EQ:
        return TokenType.STAR;
      case TokenType.SLASH_EQ:
        return TokenType.SLASH;
      case TokenType.PERCENT_EQ:
        return TokenType.PERCENT;
      default:
        _unsupported(
          e,
          'compound assignment `${e.operator.lexeme}` is not yet supported',
        );
    }
  }

  /// Rejects a function that needs more registers than the encoding allows.
  Never _registerOverflow(String name, int needed, AstNode? at) {
    final location = at == null ? null : _lineInfo.getLocation(at.offset);
    _diagnostics.add(
      CompileDiagnostic(
        severity: DiagnosticSeverity.error,
        message:
            "function '$name' needs $needed registers; the bytecode format "
            'allows 255',
        path: _path,
        line: location?.lineNumber ?? 1,
        column: location?.columnNumber ?? 1,
        code: 'E0102',
        correction:
            'Split it into smaller functions, or reduce the number of '
            'simultaneously live locals and temporaries.',
      ),
    );
    throw const AbortCompilation();
  }

  Never _unsupported(AstNode node, String message, {String? correction}) {
    final location = _lineInfo.getLocation(node.offset);
    _diagnostics.add(
      CompileDiagnostic(
        severity: DiagnosticSeverity.error,
        message: message,
        path: _path,
        line: location.lineNumber,
        column: location.columnNumber,
        code: 'E0100',
        correction: correction,
      ),
    );
    throw const AbortCompilation();
  }
}
