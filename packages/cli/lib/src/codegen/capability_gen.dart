// Copyright (c) Ejenix authors. MIT license.

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';

/// Thrown when an annotated declaration cannot be turned into a capability —
/// e.g. a parameter whose type does not marshal across the sandbox boundary.
/// Codegen fails loudly with a fixable message rather than emitting code that
/// would break at runtime on a device.
class CapabilityGenException implements Exception {
  CapabilityGenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The two files `ejenix gen` writes: the patch SDK a patch compiles against,
/// and the host registrations that back it.
class GeneratedCapabilities {
  GeneratedCapabilities({
    required this.sdk,
    required this.capabilities,
    this.globalNames = const [],
  });

  /// The capability names this app registers, sorted.
  ///
  /// Written to a manifest so CI can answer, before publishing, whether a patch
  /// needs anything the shipped build does not have. Without it the question
  /// can only be answered on a user's phone.
  final List<String> globalNames;

  /// The patch-facing `external` declarations (`patch_sdk/app.dart`).
  final String sdk;

  /// The `HostExtension appCapabilities(...)` bindings (`*.g.dart`).
  final String capabilities;
}

/// One resolved input library plus the import a generated file uses to reach it.
class CapabilitySource {
  CapabilitySource({required this.unit, required this.importPath});
  final ResolvedUnitResult unit;

  /// How the generated capabilities file imports this source (a relative path
  /// or a `package:` URI).
  final String importPath;
}

/// Reads `@Patchable` annotations off resolved app code and generates both the
/// patch SDK and the matching host registrations. Deterministic: the same input
/// yields byte-identical output, declarations in source order.
class CapabilityGenerator {
  /// The `flutter.dart` import the generated SDK expects beside it.
  final String sdkFrameworkImport;

  CapabilityGenerator({this.sdkFrameworkImport = 'flutter.dart'});

  GeneratedCapabilities generate(List<CapabilitySource> sources) {
    final caps = <_Cap>[];
    for (final source in sources) {
      for (final decl in source.unit.unit.declarations) {
        _collect(decl, source.importPath, caps);
      }
    }
    if (caps.isEmpty) {
      throw CapabilityGenException(
        'no @Patchable declarations found in the given files',
      );
    }
    return GeneratedCapabilities(
      sdk: _renderSdk(caps),
      capabilities: _renderCapabilities(caps, sources),
      globalNames: [for (final c in caps) c.exposed]..sort(),
    );
  }

  // --- Collection ------------------------------------------------------------

  void _collect(CompilationUnitMember decl, String importPath, List<_Cap> out) {
    if (decl is ClassDeclaration) {
      final onClass = _patchableName(decl.metadata);
      if (onClass.annotated) {
        out.add(_widgetCap(decl, onClass.name, importPath));
        return; // A patchable class is a widget; its members are not scanned.
      }
      for (final member in decl.body.members) {
        if (member is MethodDeclaration) {
          final m = _patchableName(member.metadata);
          if (m.annotated) {
            out.add(_memberCap(decl, member, m.name, m.rebuild, importPath));
          }
        }
      }
    } else if (decl is FunctionDeclaration) {
      final f = _patchableName(decl.metadata);
      if (f.annotated) {
        out.add(_functionCap(decl, f.name, f.rebuild, importPath));
      }
    }
  }

  _Cap _widgetCap(ClassDeclaration decl, String? name, String importPath) {
    final className = decl.namePart.typeName.lexeme;
    final ctor = decl.body.members
        .whereType<ConstructorDeclaration>()
        .where((c) => c.name == null)
        .firstOrNull;
    final params = <_Param>[];
    if (ctor != null) {
      for (final p in ctor.parameters.parameters) {
        if (p.name?.lexeme == 'key')
          continue; // Framework plumbing, not an arg.
        final param = _paramFromNode(p, className);
        if (param != null) params.add(param);
      }
    }
    return _Cap(
      exposed: name ?? className,
      kind: _Kind.widget,
      realTarget: className,
      isGetter: false,
      returnType: null,
      params: params,
      importPath: importPath,
    );
  }

  _Cap _memberCap(
    ClassDeclaration owner,
    MethodDeclaration member,
    String? name,
    bool rebuild,
    String importPath,
  ) {
    final ownerName = owner.namePart.typeName.lexeme;
    final memberName = member.name.lexeme;
    final params = <_Param>[];
    final list = member.parameters;
    if (list != null && !member.isGetter) {
      for (final p in list.parameters) {
        final param = _paramFromNode(p, '$ownerName.$memberName');
        if (param != null) params.add(param);
      }
    }
    final receiver = member.isStatic ? ownerName : _instanceVar(ownerName);
    return _Cap(
      exposed: name ?? memberName,
      kind: member.isStatic ? _Kind.staticMember : _Kind.instanceMember,
      realTarget: '$receiver.$memberName',
      instanceClass: member.isStatic ? null : ownerName,
      isGetter: member.isGetter,
      returnType: member.returnType?.type,
      params: params,
      importPath: importPath,
      rebuild: rebuild,
    );
  }

  _Cap _functionCap(
    FunctionDeclaration decl,
    String? name,
    bool rebuild,
    String importPath,
  ) {
    final fnName = decl.name.lexeme;
    final params = <_Param>[];
    final list = decl.functionExpression.parameters;
    if (list != null && !decl.isGetter) {
      for (final p in list.parameters) {
        final param = _paramFromNode(p, fnName);
        if (param != null) params.add(param);
      }
    }
    return _Cap(
      exposed: name ?? fnName,
      kind: _Kind.function,
      realTarget: fnName,
      isGetter: decl.isGetter,
      returnType: decl.returnType?.type,
      params: params,
      importPath: importPath,
      rebuild: rebuild,
    );
  }

  _Param? _paramFromNode(FormalParameter p, String where) {
    final name = p.name?.lexeme;
    if (name == null) return null;
    final type = _typeOf(p);
    final access = "m['$name']";
    return _Param(
      name: name,
      sdkType: type == null ? 'Object?' : _sdkType(type),
      isNamed: p.isNamed,
      isRequiredNamed: p.isRequiredNamed,
      marshal: type == null
          ? access
          : _marshal(type, access, where, name, _defaultOf(p)),
    );
  }

  DartType? _typeOf(FormalParameter p) => p.declaredFragment?.element.type;

  /// The parameter's declared default, as written in the source.
  ///
  /// A patch that omits an optional argument must get the default the author
  /// declared, not the type's zero value. Falling back to the zero silently
  /// inverts `{this.enabled = true}` into a permanently disabled widget — the
  /// argument looks honoured and behaves backwards.
  ///
  /// The generated file imports the library the parameter was declared in, so a
  /// default naming a constant from that library still resolves.
  String? _defaultOf(FormalParameter p) =>
      p.declaredFragment?.element.defaultValueCode;

  // --- Rendering: the patch SDK ---------------------------------------------

  String _renderSdk(List<_Cap> caps) {
    final b = StringBuffer()
      ..writeln('// GENERATED BY `ejenix gen` — do not edit by hand.')
      ..writeln(
        '// Regenerate with `ejenix gen` after changing @Patchable code.',
      )
      ..writeln('library;')
      ..writeln()
      ..writeln("import '$sdkFrameworkImport';");

    // Widgets and top-level functions render loose; namespaced members group.
    final namespaces = <String, List<_Cap>>{};
    for (final c in caps) {
      final ns = c.namespace;
      if (ns != null) {
        (namespaces[ns] ??= []).add(c);
      } else if (c.kind == _Kind.widget) {
        b
          ..writeln()
          ..writeln('class ${c.member} implements Widget {')
          ..writeln('  external ${c.member}(${_sdkParams(c.params)});')
          ..writeln('}');
      } else {
        b
          ..writeln()
          ..writeln(_sdkExternal(c, isStatic: false));
      }
    }
    namespaces.forEach((ns, members) {
      b
        ..writeln()
        ..writeln('class $ns {');
      for (final c in members) {
        b.writeln('  ${_sdkExternal(c, isStatic: true)}');
      }
      b.writeln('}');
    });
    return b.toString();
  }

  String _sdkExternal(_Cap c, {required bool isStatic}) {
    final ret = c.returnType == null ? 'void' : _sdkType(c.returnType!);
    final mods = isStatic ? 'external static ' : 'external ';
    if (c.isGetter) return '$mods$ret get ${c.member};';
    return '$mods$ret ${c.member}(${_sdkParams(c.params)});';
  }

  String _sdkParams(List<_Param> params) {
    final positional = params.where((p) => !p.isNamed).toList();
    final named = params.where((p) => p.isNamed).toList();
    final parts = [for (final p in positional) '${p.sdkType} ${p.name}'];
    if (named.isNotEmpty) {
      final inner = [
        for (final p in named)
          '${p.isRequiredNamed ? 'required ' : ''}${p.sdkType} ${p.name}',
      ].join(', ');
      parts.add('{$inner}');
    }
    return parts.join(', ');
  }

  // --- Rendering: the host registrations ------------------------------------

  String _renderCapabilities(List<_Cap> caps, List<CapabilitySource> sources) {
    final instanceClasses = <String>[
      for (final c in caps)
        if (c.instanceClass != null) c.instanceClass!,
    ].toSet().toList();

    final uris = <String>{
      'package:ejenix_flutter/ejenix_flutter.dart',
      // `Widget` and the `SizedBox.shrink()` fallback are named in the bindings
      // whenever a capability takes one, and neither is in scope from the
      // bridge import alone.
      if (caps.any((c) => c.params.any((p) => p.marshal.contains('Widget'))))
        'package:flutter/widgets.dart',
      for (final s in sources) s.importPath,
    };

    final b = StringBuffer()
      ..writeln('// GENERATED BY `ejenix gen` — do not edit by hand.')
      ..writeln(
        '// Regenerate with `ejenix gen` after changing @Patchable code.',
      )
      ..writeln('library;')
      ..writeln();
    for (final uri in _orderedImports(uris)) {
      b.writeln("import '$uri';");
    }

    final args = [
      for (final c in instanceClasses) '$c ${_instanceVar(c)}',
    ].join(', ');
    b
      ..writeln()
      ..writeln(
        '/// Grants a patch exactly the capabilities marked @Patchable.',
      )
      ..writeln('/// Pass the result to `EjenixPatchView(extend: ...)`.')
      ..writeln('HostExtension appCapabilities($args) {')
      ..writeln('  return (registry, ctx) {')
      ..write('    registry');
    for (final c in caps) {
      b
        ..writeln()
        ..write('      ..registerGlobal(${_quote(c.exposed)}, ${_binding(c)})');
    }
    b
      ..writeln(';')
      ..writeln('  };')
      ..writeln('}');
    return b.toString();
  }

  String _binding(_Cap c) {
    final call = c.isGetter
        ? c.realTarget
        : '${c.realTarget}(${_callArgs(c.params)})';

    // A `rebuild:` capability mutates state the patch does not own, so it asks
    // the view to rebuild afterwards — awaiting a Future first.
    if (c.rebuild && c.kind != _Kind.widget && !c.isGetter) {
      const rb = 'ctx.requestRebuild?.call();';
      final invoke = _isFuture(c.returnType) ? 'await $call' : call;
      final asyncMod = _isFuture(c.returnType) ? 'async ' : '';
      if (c.params.isEmpty) {
        return '(_, __) $asyncMod{ $invoke; $rb return null; }';
      }
      return '(_, a) $asyncMod{ final m = ctx.args(a); $invoke; $rb return null; }';
    }

    final isVoid = c.kind != _Kind.widget && _isVoid(c.returnType);
    if (c.params.isEmpty) {
      return isVoid ? '(_, __) { $call; return null; }' : '(_, __) => $call';
    }
    const head = 'final m = ctx.args(a);';
    return isVoid
        ? '(_, a) { $head $call; return null; }'
        : '(_, a) { $head return $call; }';
  }

  String _callArgs(List<_Param> params) => [
    for (final p in params) p.isNamed ? '${p.name}: ${p.marshal}' : p.marshal,
  ].join(', ');

  // --- Type marshalling ------------------------------------------------------

  /// The expression that pulls one argument out of the `{name: value}` map and
  /// coerces it to what the real code expects. The heart of the sandbox
  /// boundary: only cleanly-marshalable input types are accepted.
  String _marshal(
    DartType type,
    String access,
    String where,
    String name, [
    String? declaredDefault,
  ]) {
    if (type is FunctionType) {
      final ps = type.formalParameters;
      if (ps.isEmpty) return 'ctx.callback($access)';
      if (ps.length == 1) {
        return 'ctx.callbackWith<${_sdkType(ps.first.type)}>($access)';
      }
      throw CapabilityGenException(
        "$where: callback '$name' takes ${ps.length} arguments; codegen "
        'supports 0- or 1-argument callbacks. Wrap it or expose a simpler one.',
      );
    }
    // What an omitted argument falls back to: the author's declared default
    // when there is one, and only otherwise the type's zero.
    String fallback(String zero) => declaredDefault ?? zero;

    if (_isWidget(type)) {
      // A Widget has no zero value, so a non-nullable slot needs an explicit
      // empty widget or the cast lands a `Widget?` in a `Widget` parameter.
      return _isNullable(type)
          ? '$access as Widget?'
          : '$access as Widget? ?? ${fallback('const SizedBox.shrink()')}';
    }
    final nullable = _isNullable(type);
    if (type.isDartCoreString) {
      return nullable
          ? '$access as String?'
          : "$access as String? ?? ${fallback("''")}";
    }
    if (type.isDartCoreInt) {
      return nullable
          ? '$access as int?'
          : '$access as int? ?? ${fallback('0')}';
    }
    if (type.isDartCoreDouble) {
      return nullable
          ? '$access as double?'
          : '$access as double? ?? ${fallback('0.0')}';
    }
    if (type.isDartCoreNum) {
      return nullable
          ? '$access as num?'
          : '$access as num? ?? ${fallback('0')}';
    }
    if (type.isDartCoreBool) {
      return nullable
          ? '$access as bool?'
          : '$access as bool? ?? ${fallback('false')}';
    }
    if (type.isDartCoreObject || type is DynamicType) return access;
    throw CapabilityGenException(
      "$where: parameter '$name' has type '${type.getDisplayString()}', which "
      'does not marshal across the sandbox. Inputs must be String, int, double, '
      'num, bool, Object?, a Widget, or a 0-/1-argument callback.',
    );
  }

  /// The type as it should appear in the patch SDK: a Widget subtype narrows to
  /// `Widget` (all a patch knows), a callback typedef expands to its function
  /// form (the patch SDK defines `void Function()`, not `VoidCallback`), and
  /// everything else keeps its display form.
  String _sdkType(DartType type) {
    if (_isWidget(type)) return _isNullable(type) ? 'Widget?' : 'Widget';
    if (type is FunctionType) return _functionTypeString(type);
    return type.getDisplayString();
  }

  /// A function type written out (`void Function(String)?`) rather than under an
  /// alias like `VoidCallback` or `ValueChanged<String>`, which the patch SDK
  /// has no declaration for.
  String _functionTypeString(FunctionType type) {
    final ret = _sdkType(type.returnType);
    final params = type.formalParameters
        .map((p) => _sdkType(p.type))
        .join(', ');
    return '$ret Function($params)${_isNullable(type) ? '?' : ''}';
  }

  bool _isWidget(DartType type) {
    if (type is! InterfaceType) return false;
    if (_baseName(type) == 'Widget') return true;
    return type.allSupertypes.any((s) => _baseName(s) == 'Widget');
  }

  /// A type's display form without nullability or type arguments (`List<int>?`
  /// → `List`), for name-based classification.
  String _baseName(DartType type) {
    var d = type.getDisplayString();
    if (d.endsWith('?')) d = d.substring(0, d.length - 1);
    final lt = d.indexOf('<');
    return lt < 0 ? d : d.substring(0, lt);
  }

  bool _isVoid(DartType? type) => type == null || type is VoidType;
  bool _isFuture(DartType? type) =>
      type != null && (type.isDartAsyncFuture || type.isDartAsyncFutureOr);
  bool _isNullable(DartType type) => type.getDisplayString().endsWith('?');

  // --- Small helpers ---------------------------------------------------------

  _AnnMatch _patchableName(NodeList<Annotation> metadata) {
    for (final a in metadata) {
      final n = a.name.name;
      if (n == 'patchable' ||
          n == 'Patchable' ||
          n.endsWith('.patchable') ||
          n.endsWith('.Patchable')) {
        String? name;
        var rebuild = false;
        for (final arg in a.arguments?.arguments ?? const <Expression>[]) {
          if (arg is SimpleStringLiteral) name = arg.value;
          if (arg is BooleanLiteral) rebuild = arg.value;
        }
        return _AnnMatch(annotated: true, name: name, rebuild: rebuild);
      }
    }
    return const _AnnMatch(annotated: false, name: null, rebuild: false);
  }

  String _instanceVar(String className) =>
      className[0].toLowerCase() + className.substring(1);

  String _quote(String s) => "'${s.replaceAll("'", r"\'")}'";

  /// Import URIs in idiomatic order — `dart:`, then `package:`, then relative —
  /// each group alphabetical, so the generated file satisfies `directives_
  /// ordering` without a formatter pass.
  List<String> _orderedImports(Set<String> uris) {
    int rank(String u) =>
        u.startsWith('dart:') ? 0 : (u.startsWith('package:') ? 1 : 2);
    return uris.toList()..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
  }
}

enum _Kind { widget, staticMember, instanceMember, function }

class _Cap {
  _Cap({
    required this.exposed,
    required this.kind,
    required this.realTarget,
    required this.isGetter,
    required this.returnType,
    required this.params,
    required this.importPath,
    this.instanceClass,
    this.rebuild = false,
  });

  final String exposed;
  final _Kind kind;

  /// Whether the binding requests a view rebuild after the call.
  final bool rebuild;

  /// The real Dart expression to invoke: a class name (widget ctor), a
  /// `Class.member` (static), an `instanceVar.member` (instance), or a bare
  /// function name.
  final String realTarget;
  final String? instanceClass;
  final bool isGetter;
  final DartType? returnType;
  final List<_Param> params;
  final String importPath;

  /// The namespace part of [exposed] (before a `.`), or null for a top-level
  /// name. Widgets never namespace.
  String? get namespace {
    final dot = exposed.indexOf('.');
    return dot < 0 ? null : exposed.substring(0, dot);
  }

  /// The member part of [exposed] (after a `.`), or the whole name.
  String get member {
    final dot = exposed.indexOf('.');
    return dot < 0 ? exposed : exposed.substring(dot + 1);
  }
}

class _Param {
  _Param({
    required this.name,
    required this.sdkType,
    required this.isNamed,
    required this.isRequiredNamed,
    required this.marshal,
  });
  final String name;
  final String sdkType;
  final bool isNamed;
  final bool isRequiredNamed;
  final String marshal;
}

class _AnnMatch {
  const _AnnMatch({
    required this.annotated,
    required this.name,
    required this.rebuild,
  });
  final bool annotated;
  final String? name;
  final bool rebuild;
}
