// Copyright (c) Ejenix authors. MIT license.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:ejenix_bytecode/bytecode.dart';
import 'package:path/path.dart' as p;

import 'diagnostic.dart';
import 'function_compiler.dart';

/// The outcome of a compilation: the emitted [module] (or `null` on failure)
/// and the [diagnostics] produced.
class CompileResult {
  /// Creates a result.
  CompileResult(this.module, this.diagnostics);

  /// The compiled module, or `null` if compilation failed.
  final Module? module;

  /// All diagnostics, in source order.
  final List<CompileDiagnostic> diagnostics;

  /// Whether any diagnostic is a fatal error.
  bool get hasErrors => diagnostics.any((d) => d.isError);

  /// The error diagnostics only.
  Iterable<CompileDiagnostic> get errors => diagnostics.where((d) => d.isError);

  /// The module, or throws [CompileException] if compilation failed.
  Module get moduleOrThrow {
    final module = this.module;
    if (module == null || hasErrors) throw CompileException(diagnostics);
    return module;
  }
}

/// A compiler that keeps its analysis context **warm** across rebuilds.
///
/// [Compiler.compileFile] constructs a fresh `AnalysisContextCollection` per
/// call and throws it away. That is the right default — it is hermetic, and a
/// one-shot build pays the cost once — but it re-reads and re-resolves the SDK
/// and every dependency on *every* call, which costs seconds. A watch loop
/// rebuilds on every save, so paying that repeatedly is what would make a fast
/// dev loop impossible.
///
/// This variant holds one context open and tells the analyzer only what changed
/// ([invalidate]), so a rebuild re-resolves the edited library and reuses
/// everything else. That is what makes the sub-500ms round-trip achievable
/// (`spec/../docs/benchmarks.md`).
///
/// It is **not** a drop-in replacement for [Compiler]: it holds OS resources and
/// assumes the files under [includedPaths] are the ones being edited. Call
/// [invalidate] for every changed path before [compile], or the analyzer will
/// happily return a stale result. Use [Compiler] for one-shot builds.
class IncrementalCompiler {
  /// Opens a warm context rooted at [includedPaths] — typically the patch
  /// source's directory and the patch SDK's, so edits to either are seen.
  IncrementalCompiler({required List<String> includedPaths})
    : _collection = AnalysisContextCollection(
        includedPaths: [
          for (final path in includedPaths) p.normalize(p.absolute(path)),
        ],
      );

  final AnalysisContextCollection _collection;
  final Compiler _compiler = Compiler();

  /// Tells the analyzer [path]'s contents changed on disk, so the next [compile]
  /// re-reads it instead of serving a cached resolution.
  void invalidate(String path) {
    final absolute = p.normalize(p.absolute(path));
    for (final context in _collection.contexts) {
      context.changeFile(absolute);
    }
  }

  /// Compiles [path] against the warm context.
  Future<CompileResult> compile(String path) async {
    final absolute = p.normalize(p.absolute(path));
    final context = _collection.contextFor(absolute);
    // Must precede the resolve: the analyzer defers the work [invalidate]
    // queued until this is awaited.
    await context.applyPendingFileChanges();

    final resolved = await context.currentSession.getResolvedUnit(absolute);
    if (resolved is! ResolvedUnitResult) {
      return CompileResult(null, [
        CompileDiagnostic(
          severity: DiagnosticSeverity.error,
          message: 'could not resolve source',
          path: path,
          line: 1,
          column: 1,
          code: 'E0001',
        ),
      ]);
    }
    return _compiler._compileUnit(resolved, path);
  }

  /// Releases the analysis context. The instance is unusable afterwards.
  ///
  /// Idempotent: disposing an already-disposed collection **hangs** rather than
  /// throwing, so a second owner calling this must be a no-op, not a deadlock.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _collection.dispose();
  }

  bool _disposed = false;
}

/// Compiles a subset of Dart source to Ejenix bytecode.
///
/// The pipeline is: resolve with the analyzer frontend, surface any analyzer
/// errors, collect the unit's top-level functions, then lower each to bytecode
/// with a [FunctionCompiler]. Output is deterministic — the same source and
/// compiler version yield byte-identical modules (brief §6.2, §10.4).
///
/// For a rebuild-on-save loop, use [IncrementalCompiler] instead: this class
/// pays full analyzer start-up on every call.
class Compiler {
  /// Compiles in-memory [source]. [path] is used only for diagnostic messages.
  Future<CompileResult> compileSource(
    String source, {
    String path = 'input.dart',
  }) async {
    final dir = Directory.systemTemp.createTempSync('ejenix_compile');
    try {
      final file = File(p.join(dir.path, 'unit.dart'))
        ..writeAsStringSync(source);
      return await compileFile(file.path, displayPath: path);
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best-effort cleanup of the scratch directory.
      }
    }
  }

  /// Compiles the Dart file at [path]. [displayPath], when given, replaces the
  /// on-disk path in diagnostics (used by [compileSource]).
  Future<CompileResult> compileFile(String path, {String? displayPath}) async {
    final absolute = p.normalize(p.absolute(path));
    final collection = AnalysisContextCollection(includedPaths: [absolute]);
    try {
      final session = collection.contextFor(absolute).currentSession;
      final resolved = await session.getResolvedUnit(absolute);
      if (resolved is! ResolvedUnitResult) {
        return CompileResult(null, [
          CompileDiagnostic(
            severity: DiagnosticSeverity.error,
            message: 'could not resolve source',
            path: displayPath ?? path,
            line: 1,
            column: 1,
            code: 'E0001',
          ),
        ]);
      }
      return _compileUnit(resolved, displayPath ?? path);
    } finally {
      await collection.dispose();
    }
  }

  CompileResult _compileUnit(ResolvedUnitResult resolved, String path) {
    final diagnostics = <CompileDiagnostic>[];

    // 1. Surface analyzer errors (syntax + resolution). A source that does not
    //    analyze cleanly never reaches lowering.
    for (final d in resolved.diagnostics) {
      if (d.severity == Severity.error) {
        final loc = resolved.lineInfo.getLocation(d.offset);
        diagnostics.add(
          CompileDiagnostic(
            severity: DiagnosticSeverity.error,
            message: d.message,
            path: path,
            line: loc.lineNumber,
            column: loc.columnNumber,
            code: 'E0000',
          ),
        );
      }
    }
    if (diagnostics.any((d) => d.isError))
      return CompileResult(null, diagnostics);

    // 1b. Sandbox boundary: native, reflective, and isolate libraries are
    //     permanently forbidden (brief §6.2, §6.10) — the interpreter's whole
    //     safety model is that bytecode reaches the host only through the
    //     allow-list, which these libraries would bypass. Report precisely.
    const forbiddenImports = {
      'dart:ffi': 'native code and raw memory access',
      'dart:mirrors': 'reflection, which would bypass the host allow-list',
      'dart:isolate': 'spawning uncontrolled isolates',
      // Compiled fine until now, which broke the promise the docs make and the
      // one this compiler is built around: what a patch cannot reach should
      // fail here, not on a user's device. The host registers no File, Socket,
      // or Process capability, so `dart:io` code always failed — but it failed
      // at runtime, as a fallback and a rollback, instead of as a build error.
      'dart:io': 'filesystem, socket, and process access outside the sandbox',
    };
    for (final directive
        in resolved.unit.directives.whereType<ImportDirective>()) {
      final reason = forbiddenImports[directive.uri.stringValue];
      if (reason != null) {
        _reportError(
          diagnostics,
          resolved,
          path,
          directive.offset,
          '`${directive.uri.stringValue}` is not permitted in the sandbox '
          '($reason)',
          correction:
              'expose only the specific capability you need through the host '
              'API (HostRegistry), rather than importing this library',
          code: 'E0200',
        );
      }
    }
    if (diagnostics.any((d) => d.isError)) {
      return CompileResult(null, diagnostics);
    }

    // 2. Collect top-level functions, classes, and enums.
    final functionDecls = <FunctionDeclaration>[];
    final classDecls = <ClassDeclaration>[];
    final mixinDecls = <Element, MixinDeclaration>{};
    final extensionDecls = <ExtensionDeclaration>[];
    final extensionTypeDecls = <ExtensionTypeDeclaration>[];
    final enumValues = <Element, EnumValue>{};
    final enumMembers = <Element, List<EnumValue>>{};
    for (final decl in resolved.unit.declarations) {
      if (decl is FunctionDeclaration && !decl.isGetter && !decl.isSetter) {
        functionDecls.add(decl);
      } else if (decl is ClassDeclaration) {
        classDecls.add(decl);
      } else if (decl is MixinDeclaration) {
        // Mixins are not compiled standalone; their members are folded into
        // each class that applies them (see the `with`-clause handling below).
        final element = decl.declaredFragment?.element;
        if (element != null) mixinDecls[element] = decl;
      } else if (decl is ExtensionDeclaration) {
        extensionDecls.add(decl);
      } else if (decl is ExtensionTypeDeclaration) {
        extensionTypeDecls.add(decl);
      } else if (decl is TypeAlias) {
        // A `typedef` is purely type-level; types are erased at runtime, so the
        // alias contributes no code. The analyzer has already resolved uses.
        continue;
      } else if (decl is EnumDeclaration) {
        _collectEnum(decl, enumValues, enumMembers);
      } else {
        _reportError(
          diagnostics,
          resolved,
          path,
          decl.offset,
          'top-level `${astKindName(decl)}` is not yet supported',
        );
      }
    }
    if (diagnostics.any((d) => d.isError)) {
      return CompileResult(null, diagnostics);
    }

    // 3. Plan: assign function indices and build class layouts + descriptors.
    //    Each task is a thunk compiled in Phase 5, after every layout is known.
    final constants = ConstantPool();
    final callSites = <CallSite>[];
    final functionIndices = <Element, int>{};
    final classLayouts = <Element, ClassLayout>{};
    final classDescriptors = <ClassDescriptor>[];
    final sink = ProtoSink();
    final tasks = <(int, FunctionProto Function())>[];

    // Static fields live in module-level globals, keyed by element. Their
    // initializers run once (eagerly) in a synthetic static-initializer.
    final staticFields = <Element, int>{};
    final staticFieldInits = <(int, Expression)>[];

    // Every instance method's function index, keyed by element, so an explicit
    // `super.method(...)` can statically dispatch to the superclass version.
    final methodIndices = <Element, int>{};

    // Extension-type elements mapped to their representation field name, so
    // construction and representation access lower to identity.
    final extensionTypes = <Element, String>{};

    FunctionCompiler make({
      ClassLayout? enclosing,
      bool isExtension = false,
      String? extensionRepName,
    }) => FunctionCompiler(
      constants: constants,
      functionIndices: functionIndices,
      callSites: callSites,
      path: path,
      lineInfo: resolved.lineInfo,
      diagnostics: diagnostics,
      sink: sink,
      classLayouts: classLayouts,
      enclosingClass: enclosing,
      enumValues: enumValues,
      enumMembers: enumMembers,
      staticFields: staticFields,
      methodIndices: methodIndices,
      extensionTypes: extensionTypes,
      extensionRepName: extensionRepName,
      isExtension: isExtension,
    );

    for (final fn in functionDecls) {
      final element = fn.declaredFragment?.element;
      if (element == null) continue;
      // An `external` function has no body; calls dispatch to a host global of
      // the same name (the embedder provides it), so it is not compiled here.
      if (fn.externalKeyword != null) continue;
      final index = sink.reserve();
      functionIndices[element] = index;
      tasks.add((index, () => make().compile(fn)));
    }

    // Extension members compile to functions taking the receiver as `this`
    // (register 0); a call resolves the member element to this index and
    // dispatches statically.
    for (final ext in extensionDecls) {
      for (final member in ext.body.members.whereType<MethodDeclaration>()) {
        if (member.body is EmptyFunctionBody ||
            member.isStatic ||
            member.isSetter) {
          _reportError(
            diagnostics,
            resolved,
            path,
            member.offset,
            'this extension member form is not yet supported',
          );
          continue;
        }
        final element = member.declaredFragment?.element;
        if (element == null) continue;
        final index = sink.reserve();
        functionIndices[element] = index;
        tasks.add((
          index,
          () => make(isExtension: true).compileExtensionMember(member),
        ));
      }
    }

    // Extension types are erased to their representation: construction is
    // identity, the representation getter is identity, and members compile like
    // extension members (receiver = the representation value).
    for (final ext in extensionTypeDecls) {
      final typeElement = ext.declaredFragment?.element;
      if (typeElement == null) continue;
      final repName = _extensionTypeRepName(ext);
      if (repName != null) extensionTypes[typeElement] = repName;
      for (final member in ext.body.members.whereType<MethodDeclaration>()) {
        if (member.body is EmptyFunctionBody ||
            member.isStatic ||
            member.isSetter) {
          continue;
        }
        final element = member.declaredFragment?.element;
        if (element == null) continue;
        final index = sink.reserve();
        functionIndices[element] = index;
        tasks.add((
          index,
          () => make(
            isExtension: true,
            extensionRepName: repName,
          ).compileExtensionMember(member),
        ));
      }
    }

    for (final cls in _topologicalClasses(classDecls)) {
      final classElement = cls.declaredFragment?.element;
      if (classElement == null) continue;
      final classIndex = classDescriptors.length;

      final superElement = cls.extendsClause?.superclass.element;
      final superLayout = superElement == null
          ? null
          : classLayouts[superElement];
      final superIndex = superLayout?.classIndex ?? -1;
      final superDescriptor = superIndex == -1
          ? null
          : classDescriptors[superIndex];

      // Members contributed to this class, in resolution order: applied mixins
      // (left to right) then the class's own body. A later declaration overrides
      // an earlier one, matching Dart's mixin linearization. Mixin members are
      // compiled fresh against *this* class's layout, so their field slots and
      // `this`-dispatch resolve to the host class.
      final memberSources = <ClassMember>[];
      for (final mixinType
          in cls.withClause?.mixinTypes ?? const <NamedType>[]) {
        final mixinDecl = mixinDecls[mixinType.element];
        if (mixinDecl == null) {
          _reportError(
            diagnostics,
            resolved,
            path,
            mixinType.offset,
            'mixin `${mixinType.name.lexeme}` must be declared in this unit',
          );
          continue;
        }
        memberSources.addAll(mixinDecl.body.members);
      }
      memberSources.addAll(cls.body.members);

      final fieldsByName = <String, int>{...?superLayout?.fieldsByName};
      var nextSlot = superDescriptor?.fieldCount ?? 0;
      final fieldInitializers = <(int, Expression)>[];
      for (final member in memberSources.whereType<FieldDeclaration>()) {
        if (member.isStatic) {
          // A static field is a module global; its initializer runs in the
          // static initializer. Deduplicated (a mixin-folded static once).
          for (final variable in member.fields.variables) {
            final element = variable.declaredFragment?.element;
            if (element == null || staticFields.containsKey(element)) continue;
            final globalIndex = staticFields.length;
            staticFields[element] = globalIndex;
            final initializer = variable.initializer;
            if (initializer != null) {
              staticFieldInits.add((globalIndex, initializer));
            }
          }
          continue;
        }
        for (final variable in member.fields.variables) {
          final slot = nextSlot++;
          fieldsByName[variable.name.lexeme] = slot;
          final initializer = variable.initializer;
          if (initializer != null) fieldInitializers.add((slot, initializer));
        }
      }
      final fieldCount = nextSlot;

      // Collect every constructor (generative + factory), keyed by name (`''`
      // for the unnamed one). Factories compile to plain functions; generatives
      // take `this`.
      final constructors = <String, int>{};
      final factories = <String>{};
      final ctorPlan = <(int, ConstructorDeclaration)>[];
      ConstructorDeclaration? unnamedGenerative;
      for (final ctor in cls.body.members.whereType<ConstructorDeclaration>()) {
        final name = ctor.name?.lexeme ?? '';
        final index = sink.reserve();
        constructors[name] = index;
        if (ctor.factoryKeyword != null) {
          factories.add(name);
        } else if (name.isEmpty) {
          unnamedGenerative = ctor;
        }
        ctorPlan.add((index, ctor));
      }
      // A generative unnamed constructor anchors `super()` and default `new C()`;
      // synthesize a default one when the class declares none.
      final int constructorIndex;
      var needsDefaultTask = false;
      if (unnamedGenerative != null) {
        constructorIndex = constructors['']!;
      } else {
        constructorIndex = sink.reserve();
        constructors.putIfAbsent('', () => constructorIndex);
        needsDefaultTask = true;
      }

      final layout = ClassLayout(
        classIndex: classIndex,
        constructorIndex: constructorIndex,
        fieldsByName: fieldsByName,
        classElement: classElement,
        constructors: constructors,
        factories: factories,
      );
      classLayouts[classElement] = layout;
      final className = cls.namePart.typeName.lexeme;
      final superConstructorIndex = superLayout?.constructorIndex ?? -1;

      String ctorName(String name) =>
          name.isEmpty ? className : '$className.$name';
      for (final (index, ctor) in ctorPlan) {
        final name = ctor.name?.lexeme ?? '';
        if (factories.contains(name)) {
          tasks.add((
            index,
            () => make(enclosing: layout).compileFactory(ctor),
          ));
        } else {
          tasks.add((
            index,
            () => make(enclosing: layout).compileConstructor(
              ctor,
              ctorName(name),
              fieldInitializers,
              superConstructorIndex,
            ),
          ));
        }
      }
      if (needsDefaultTask) {
        tasks.add((
          constructorIndex,
          () => make(enclosing: layout).compileConstructor(
            null,
            className,
            fieldInitializers,
            superConstructorIndex,
          ),
        ));
      }

      final methods = <String, int>{...?superDescriptor?.methods};
      for (final member in memberSources.whereType<MethodDeclaration>()) {
        // Abstract members (a mixin's or interface's signature-only methods)
        // contribute no implementation; a concrete override supplies the body.
        // `external` methods are host-provided and dispatch dynamically.
        if (member.body is EmptyFunctionBody ||
            member.externalKeyword != null) {
          continue;
        }
        if (member.isStatic) {
          // A static method is a plain function keyed by its element; `C.f(…)`
          // dispatches to it directly with no receiver. Deduplicated so a
          // mixin-folded static is collected once.
          final element = member.declaredFragment?.element;
          if (element == null || functionIndices.containsKey(element)) continue;
          final index = sink.reserve();
          functionIndices[element] = index;
          tasks.add((index, () => make().compileStaticMethod(member)));
          continue;
        }
        // An operator (`+`, `[]`, `==`, …) is an instance method whose selector
        // is the operator lexeme; `a + b` on a user type dispatches to it.
        final selector = member.isOperator
            ? _operatorSelector(member)
            : (member.isSetter ? '${member.name.lexeme}=' : member.name.lexeme);
        final methodIndex = sink.reserve();
        methods[selector] = methodIndex;
        final methodElement = member.declaredFragment?.element;
        if (methodElement != null) methodIndices[methodElement] = methodIndex;
        tasks.add((
          methodIndex,
          () => make(enclosing: layout).compileMethod(member),
        ));
      }

      classDescriptors.add(
        ClassDescriptor(
          name: className,
          fieldCount: fieldCount,
          superIndex: superIndex,
          methods: methods,
          fields: fieldsByName,
        ),
      );
    }
    if (diagnostics.any((d) => d.isError)) {
      return CompileResult(null, diagnostics);
    }

    // 3b. A static initializer runs each static field's initializer once,
    //     writing the module globals, before the entry point.
    var staticInit = -1;
    if (staticFieldInits.isNotEmpty) {
      staticInit = sink.reserve();
      tasks.add((staticInit, () => make().compileStaticInit(staticFieldInits)));
    }

    // 4. Compile all tasks. Each task places its proto at its reserved index;
    //    closures discovered mid-compilation reserve and place further slots.
    //    An abort leaves a placeholder so indices stay aligned; the module is
    //    discarded because of the error.
    for (final (index, task) in tasks) {
      try {
        sink.place(index, task());
      } on AbortCompilation {
        sink.place(
          index,
          (BytecodeBuilder()..emitNone(Op.retVoid)).toProto(
            name: '<error>',
            paramCount: 0,
            registerCount: 1,
          ),
        );
      }
    }
    if (diagnostics.any((d) => d.isError)) {
      return CompileResult(null, diagnostics);
    }
    final protos = sink.build();

    // 5. The entry point is the top-level `main`, if present.
    var entry = -1;
    for (final fn in functionDecls) {
      if (fn.name.lexeme == 'main') {
        entry = functionIndices[fn.declaredFragment?.element] ?? -1;
        break;
      }
    }

    return CompileResult(
      Module(
        constants: constants,
        functions: protos,
        entryFunction: entry,
        callSites: callSites,
        classes: classDescriptors,
        globalCount: staticFields.length,
        staticInit: staticInit,
      ),
      diagnostics,
    );
  }

  /// Orders classes so a superclass defined in the same unit precedes its
  /// subclasses (fields and methods are inherited by index).
  /// The representation field name of an extension type (`extension type
  /// Meters(int value)` → `value`), or `null` if it cannot be determined.
  static String? _extensionTypeRepName(ExtensionTypeDeclaration ext) {
    final namePart = ext.namePart;
    if (namePart is! PrimaryConstructorDeclaration) return null;
    final params = namePart.formalParameters.parameters;
    if (params.isEmpty) return null;
    return params.first.name?.lexeme;
  }

  /// The dispatch selector for an operator method. Unary minus shares the `-`
  /// lexeme with binary minus, so it is disambiguated by arity as `unary-`.
  static String _operatorSelector(MethodDeclaration member) {
    final name = member.name.lexeme;
    if (name == '-' && (member.parameters?.parameters.isEmpty ?? true)) {
      return 'unary-';
    }
    return name;
  }

  List<ClassDeclaration> _topologicalClasses(List<ClassDeclaration> classes) {
    final byElement = <Element?, ClassDeclaration>{
      for (final c in classes) c.declaredFragment?.element: c,
    };
    final emitted = <Element>{};
    final result = <ClassDeclaration>[];
    void emit(ClassDeclaration c) {
      final element = c.declaredFragment?.element;
      if (element == null || !emitted.add(element)) return;
      final superElement = c.extendsClause?.superclass.element;
      if (superElement != null && byElement.containsKey(superElement)) {
        emit(byElement[superElement]!);
      }
      result.remove(c);
      result.add(c);
    }

    for (final c in classes) {
      emit(c);
    }
    return result;
  }

  /// Maps each of an enum's constant elements to its [EnumValue], and the enum
  /// type element to the ordered list of its values (for `Color.values`).
  void _collectEnum(
    EnumDeclaration decl,
    Map<Element, EnumValue> values,
    Map<Element, List<EnumValue>> members,
  ) {
    final enumName = decl.namePart.typeName.lexeme;
    final list = <EnumValue>[];
    for (var i = 0; i < decl.body.constants.length; i++) {
      final constant = decl.body.constants[i];
      final name = constant.name.lexeme;
      final value = EnumValue(enumName: enumName, index: i, name: name);
      list.add(value);
      final element = constant.declaredFragment?.element;
      if (element != null) values[element] = value;
    }
    final typeElement = decl.declaredFragment?.element;
    if (typeElement != null) members[typeElement] = list;
  }

  void _reportError(
    List<CompileDiagnostic> diagnostics,
    ResolvedUnitResult resolved,
    String path,
    int offset,
    String message, {
    String? correction,
    String code = 'E0101',
  }) {
    final loc = resolved.lineInfo.getLocation(offset);
    diagnostics.add(
      CompileDiagnostic(
        severity: DiagnosticSeverity.error,
        message: message,
        path: path,
        line: loc.lineNumber,
        column: loc.columnNumber,
        code: code,
        correction: correction,
      ),
    );
  }
}
