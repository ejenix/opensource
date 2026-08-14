// Copyright (c) Ejenix authors. MIT license.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// Closure-conversion analysis (brief §6.2). Two questions the compiler must
/// answer to lower closures correctly:
///
///  * Which of a function's own locals/parameters are read or written from
///    inside a nested closure? Those must be *boxed* into heap cells so the
///    closure and the enclosing scope share one mutable location — Dart captures
///    by reference. See [capturedVariables].
///  * When emitting a specific closure, which enclosing variables does it refer
///    to (its free variables / upvalues), and in what order? See [freeVariables].

/// The locals and parameters of a function body that are referenced from within
/// a nested function expression, and therefore must be boxed. Only variables
/// (locals and formal parameters) are collected; references to top-level or
/// static elements need no boxing.
Set<Element> capturedVariables(FunctionBody body) {
  final scanner = _NestedRefScanner();
  body.accept(scanner);
  return scanner.referenced;
}

/// The enclosing variables a closure [body] refers to, restricted to
/// [candidates] (the enclosing compiler's in-scope locals). Returned in order
/// of first textual appearance, which keeps the emitted upvalue indices — and
/// thus the bytecode — deterministic.
List<Element> freeVariables(FunctionBody body, Set<Element> candidates) {
  final scanner = _FreeVarScanner(candidates);
  body.accept(scanner);
  return scanner.ordered;
}

/// Whether a closure [body] refers to `this`, explicitly (`this`) or through an
/// implicit-receiver instance member (a field, getter, setter, or method). Such
/// a closure must capture the enclosing method's receiver.
bool capturesThis(FunctionBody body) {
  final scanner = _ThisScanner();
  body.accept(scanner);
  return scanner.found;
}

/// Whether any function expression nested in [body] captures `this` — the signal
/// that the enclosing method must materialize a capturable `this` cell.
bool anyNestedClosureCapturesThis(FunctionBody body) {
  final scanner = _NestedThisScanner();
  body.accept(scanner);
  return scanner.found;
}

bool _isInstanceMember(Element? e) {
  if (e is FieldElement) return !e.isStatic;
  if (e is MethodElement) return !e.isStatic;
  if (e is PropertyAccessorElement) return !e.isStatic;
  return false;
}

/// Whether [node] is the member half of a *qualified* reference — `obj.field`,
/// `obj.method()`, `obj.field = x` — rather than a bare one that implies `this`.
///
/// Only a bare reference captures the receiver. Without this check a closure
/// that merely touches some other object's field (`state.count++`, the shape
/// every stateful patch callback has) would be misread as capturing `this`.
bool _isQualified(SimpleIdentifier node) {
  final parent = node.parent;
  if (parent is PropertyAccess) return identical(parent.propertyName, node);
  if (parent is PrefixedIdentifier) return identical(parent.identifier, node);
  if (parent is MethodInvocation) {
    return identical(parent.methodName, node) && parent.target != null;
  }
  return false;
}

class _NestedRefScanner extends RecursiveAstVisitor<void> {
  int _depth = 0;
  final Set<Element> referenced = <Element>{};

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _depth++;
    super.visitFunctionExpression(node);
    _depth--;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_depth > 0) {
      final e = node.element;
      if (e != null &&
          (e is LocalVariableElement || e is FormalParameterElement)) {
        referenced.add(e);
      }
    }
    super.visitSimpleIdentifier(node);
  }
}

class _FreeVarScanner extends RecursiveAstVisitor<void> {
  _FreeVarScanner(this._candidates);
  final Set<Element> _candidates;
  final Set<Element> _seen = <Element>{};
  final List<Element> ordered = <Element>[];

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final e = node.element;
    if (e != null && _candidates.contains(e) && _seen.add(e)) {
      ordered.add(e);
    }
    super.visitSimpleIdentifier(node);
  }
}

class _ThisScanner extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitThisExpression(ThisExpression node) => found = true;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_isQualified(node) && _isInstanceMember(node.element)) found = true;
    super.visitSimpleIdentifier(node);
  }
}

/// Finds a nested function expression that captures `this`.
class _NestedThisScanner extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (capturesThis(node.body)) {
      found = true;
      return;
    }
    super.visitFunctionExpression(node);
  }
}
