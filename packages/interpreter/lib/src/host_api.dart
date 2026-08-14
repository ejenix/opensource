// Copyright (c) Ejenix authors. MIT license.

import 'dart:convert';
import 'dart:math' as math;

import 'package:ejenix_bytecode/bytecode.dart' show EnumValue;

import 'errors.dart';

/// Ceiling on elements a built-in may materialize in one call.
///
/// A UI patch that legitimately builds a list of a million elements does not
/// exist; an accidental `infiniteGenerator().toList()` does. Sized so the first
/// is impossible to hit and the second fails fast instead of hanging.
const int kMaxHostElements = 1000000;

/// Ceiling on characters a built-in may produce in one call.
const int kMaxHostStringLength = 1 << 20;

/// Drains [iterable] into a list, refusing past [kMaxHostElements].
///
/// `toList()` on a `sync*` generator that never returns is one bytecode
/// instruction and an unbounded native loop. The interpreter's per-turn budget
/// bounds each `moveNext()`, but nothing bounds how many turns get taken, so
/// the ceiling has to live here.
List<Object?> _bounded(Iterable<Object?> iterable, String capability) {
  final out = <Object?>[];
  for (final element in iterable) {
    if (out.length >= kMaxHostElements) {
      throw HostBudgetExceededException(capability, kMaxHostElements);
    }
    out.add(element);
  }
  return out;
}

/// `s * n`, refusing a result past [kMaxHostStringLength].
///
/// Checked before allocating: measuring the product afterwards would already
/// have committed the memory.
String _repeat(String s, int n) {
  if (n <= 0) return '';
  if (s.length * n > kMaxHostStringLength) {
    throw HostBudgetExceededException('String *', kMaxHostStringLength);
  }
  return s * n;
}

/// A host method: given the receiver and positional arguments, produce a result
/// by delegating to the host Dart runtime.
typedef HostMethod = Object? Function(Object? receiver, List<Object?> args);

/// The host-API allow-list (brief §6.3, §6.10).
///
/// Bytecode cannot reach the host runtime except through selectors registered
/// here, keyed by a coarse type *kind* (`String`, `int`, `List`, …) plus the
/// selector name. This is the interpreter's sandbox boundary: there is no
/// reflection (`dart:mirrors` is forbidden), so a program can only invoke the
/// operations the embedder has explicitly allowed. Getters are zero-argument
/// selectors; operators are their symbolic selectors (`+`, `[]`, `[]=`).
///
/// The normative list is `spec/host-api.md`; [HostRegistry.standard] installs
/// the default `dart:core` subset.
class HostRegistry {
  /// Creates an empty registry. Use [HostRegistry.standard] for the default
  /// `dart:core` allow-list, or register selectors manually to lock down or
  /// extend the sandbox.
  HostRegistry();

  final Map<String, HostMethod> _methods = {};
  final Map<String, HostMethod> _globals = {};
  final List<String? Function(Object?)> _kindResolvers = [];

  /// Registers [method] for [selector] on receivers of the given [kind].
  void register(String kind, String selector, HostMethod method) {
    _methods['$kind#$selector'] = method;
  }

  /// Registers a receiver-less global function [name] (e.g. `print`). The
  /// receiver passed to [method] is always `null`.
  void registerGlobal(String name, HostMethod method) =>
      _globals[name] = method;

  /// Names the [kind] of host objects an integration owns, so [register] can
  /// bind methods on them.
  ///
  /// The built-in [kindsOf] chain only knows `dart:core` types; any other host
  /// object falls through to the `Object` handlers. An integration that hands
  /// its own objects to guest code — the Flutter bridge returning a
  /// `TextEditingController`, say — registers a resolver here so those objects
  /// get a kind of their own:
  ///
  /// ```dart
  /// registry
  ///   ..addKindResolver((o) => o is TextEditingController ? 'TextEditingController' : null)
  ///   ..register('TextEditingController', 'text', (r, _) => (r as TextEditingController).text);
  /// ```
  ///
  /// Resolvers run before the built-in chain and return `null` for receivers
  /// they do not recognize. Match on the runtime **type** (`is`), never on a
  /// type-name string: names are mangled by `--obfuscate` in release builds.
  ///
  /// This does not widen the sandbox — a kind is only reachable through the
  /// selectors explicitly [register]ed for it.
  void addKindResolver(String? Function(Object? receiver) resolver) =>
      _kindResolvers.add(resolver);

  /// Resolves the global function [name], or `null` if not allowed.
  HostMethod? resolveGlobal(String name) => _globals[name];

  /// Whether global [name] is allowed. For tooling and drift checks — a host
  /// integration can assert its typed API surface and its bindings agree.
  bool hasGlobal(String name) => _globals.containsKey(name);

  /// Whether [selector] is allowed on receivers of [kind]. See [hasGlobal].
  bool hasMethod(String kind, String selector) =>
      _methods.containsKey('$kind#$selector');

  /// Every global this registry allows, sorted.
  ///
  /// The capability surface a build actually ships, as a value that can be
  /// written to a file and diffed. Without this a caller can only ask about one
  /// name at a time ([hasGlobal]), which is enough to check a patch already in
  /// hand but not to answer the question that prevents the outage: *does this
  /// bundle need anything my app does not have?* — asked in CI, before publish.
  ///
  /// Sorted so a manifest is stable across runs and a diff shows real changes.
  List<String> get globalNames => _globals.keys.toList()..sort();

  /// Every `kind#selector` this registry allows on a receiver, sorted.
  ///
  /// The other half of the allow-list. Bridge growth (`snapshot.hasData`,
  /// `controller.clear()`) drifts here rather than in [globalNames], so a
  /// manifest that omits it under-reports what a build can run.
  List<String> get methodNames => _methods.keys.toList()..sort();

  /// Resolves the handler for [selector] on [receiver], searching from the most
  /// specific kind to the `Object` fallback, or `null` if none is allowed.
  /// Kinds contributed by [addKindResolver] are searched first.
  HostMethod? resolve(Object? receiver, String selector) {
    for (final resolver in _kindResolvers) {
      final kind = resolver(receiver);
      if (kind == null) continue;
      final method = _methods['$kind#$selector'];
      if (method != null) return method;
    }
    for (final kind in kindsOf(receiver)) {
      final method = _methods['$kind#$selector'];
      if (method != null) return method;
    }
    return null;
  }

  /// The kind chain for [receiver], most specific first, ending in `Object`.
  static Iterable<String> kindsOf(Object? receiver) sync* {
    switch (receiver) {
      case String():
        yield 'String';
      case int():
        yield 'int';
        yield 'num';
      case double():
        yield 'double';
        yield 'num';
      case bool():
        yield 'bool';
      case List():
        yield 'List';
        yield 'Iterable';
      case Set():
        yield 'Set';
        yield 'Iterable';
      case Map():
        yield 'Map';
      case Duration():
        yield 'Duration';
      case Stream():
        yield 'Stream';
      case EnumValue():
        yield 'EnumValue';
      case null:
        yield 'Null';
      case Iterable():
        // A lazy iterable (e.g. a `sync*` generator's result) with no more
        // specific kind still gets the generic `Iterable` operations.
        yield 'Iterable';
      default:
        yield 'Iterator'; // host iterators fall through to Object handlers
    }
    yield 'Object';
  }

  /// The default allow-list: a curated `dart:core` subset covering the
  /// operations ordinary patch code relies on. Higher-order methods that take
  /// closures (`map`, `where`, `forEach`, …) land with the closures milestone.
  factory HostRegistry.standard() {
    final r = HostRegistry();
    _installObject(r);
    _installString(r);
    _installNum(r);
    _installBool(r);
    _installList(r);
    _installMap(r);
    _installSet(r);
    _installIterator(r);
    _installIterable(r);
    _installDuration(r);
    _installStream(r);
    _installEnum(r);
    _installGlobals(r);
    return r;
  }

  /// Generic `Iterable` operations, shared by `List`, `Set`, and lazy iterables
  /// such as a `sync*` generator's result. Lazy-returning methods (`take`,
  /// `skip`, `map`, …) stay lazy so an infinite generator can be consumed
  /// finitely; terminal methods (`fold`, `toList`, `first`, …) pull as needed.
  static void _installIterable(HostRegistry r) {
    Iterable<Object?> it(Object? x) => x as Iterable<Object?>;
    r
      ..register('Iterable', 'length', (x, _) => it(x).length)
      ..register('Iterable', 'isEmpty', (x, _) => it(x).isEmpty)
      ..register('Iterable', 'isNotEmpty', (x, _) => it(x).isNotEmpty)
      ..register('Iterable', 'first', (x, _) => it(x).first)
      ..register('Iterable', 'last', (x, _) => it(x).last)
      ..register('Iterable', 'single', (x, _) => it(x).single)
      ..register(
        'Iterable',
        'toList',
        (x, _) => _bounded(it(x), 'Iterable toList'),
      )
      ..register('Iterable', 'toSet', (x, _) => it(x).toSet())
      ..register('Iterable', 'contains', (x, a) => it(x).contains(a[0]))
      ..register(
        'Iterable',
        'elementAt',
        (x, a) => it(x).elementAt(a[0] as int),
      )
      ..register('Iterable', 'take', (x, a) => it(x).take(a[0] as int).toList())
      ..register('Iterable', 'skip', (x, a) => it(x).skip(a[0] as int).toList())
      ..register(
        'Iterable',
        'join',
        (x, a) => it(x).join(a.isEmpty ? '' : a[0] as String),
      )
      ..register('Iterable', 'iterator', (x, _) => it(x).iterator);
    _installHigherOrder(r, 'Iterable');
  }

  /// `Duration` is a value type an implicit animation or a timeout is expressed
  /// in, so a patch both constructs and reads one.
  static void _installDuration(HostRegistry r) {
    Duration d(Object? x) => x as Duration;
    r
      ..register('Duration', 'inDays', (x, _) => d(x).inDays)
      ..register('Duration', 'inHours', (x, _) => d(x).inHours)
      ..register('Duration', 'inMinutes', (x, _) => d(x).inMinutes)
      ..register('Duration', 'inSeconds', (x, _) => d(x).inSeconds)
      ..register('Duration', 'inMilliseconds', (x, _) => d(x).inMilliseconds)
      ..register('Duration', 'inMicroseconds', (x, _) => d(x).inMicroseconds)
      ..register('Duration', '+', (x, a) => d(x) + d(a[0]))
      ..register('Duration', '-', (x, a) => d(x) - d(a[0]))
      ..register('Duration', '*', (x, a) => d(x) * (a[0] as num))
      ..register('Duration', '<', (x, a) => d(x) < d(a[0]))
      ..register('Duration', '>', (x, a) => d(x) > d(a[0]));
  }

  static void _installStream(HostRegistry r) {
    Stream<Object?> s(Object? x) => x as Stream<Object?>;
    r
      // `await for` drains a stream via `toList` (a Future the loop awaits).
      ..register('Stream', 'toList', (x, _) => s(x).toList())
      ..register('Stream', 'first', (x, _) => s(x).first)
      ..register('Stream', 'length', (x, _) => s(x).length)
      ..register('Stream', 'isEmpty', (x, _) => s(x).isEmpty);
  }

  static void _installEnum(HostRegistry r) {
    EnumValue e(Object? x) => x as EnumValue;
    r
      ..register('EnumValue', 'index', (x, _) => e(x).index)
      ..register('EnumValue', 'name', (x, _) => e(x).name)
      ..register('EnumValue', 'toString', (x, _) => e(x).toString());
  }

  static void _installGlobals(HostRegistry r) {
    r
      ..registerGlobal('print', (_, a) {
        // ignore: avoid_print
        print(a.isEmpty ? '' : a[0]);
        return null;
      })
      ..registerGlobal('identical', (_, a) => identical(a[0], a[1]))
      // dart:math free functions.
      ..registerGlobal('min', (_, a) => math.min(a[0] as num, a[1] as num))
      ..registerGlobal('max', (_, a) => math.max(a[0] as num, a[1] as num))
      ..registerGlobal('sqrt', (_, a) => math.sqrt(a[0] as num))
      ..registerGlobal('pow', (_, a) => math.pow(a[0] as num, a[1] as num))
      ..registerGlobal('sin', (_, a) => math.sin(a[0] as num))
      ..registerGlobal('cos', (_, a) => math.cos(a[0] as num))
      ..registerGlobal('tan', (_, a) => math.tan(a[0] as num))
      ..registerGlobal('log', (_, a) => math.log(a[0] as num))
      ..registerGlobal('exp', (_, a) => math.exp(a[0] as num))
      // Static factory/parse methods, keyed as `Type.method`. Their single
      // argument is a `{parameterName: value}` map (the host-call convention),
      // so each reads its arguments by the SDK's parameter names.
      ..registerGlobal(
        'int.parse',
        (_, a) => int.parse(_m(a)['source'] as String),
      )
      ..registerGlobal(
        'int.tryParse',
        (_, a) => int.tryParse(_m(a)['source'] as String),
      )
      ..registerGlobal(
        'double.parse',
        (_, a) => double.parse(_m(a)['source'] as String),
      )
      ..registerGlobal(
        'double.tryParse',
        (_, a) => double.tryParse(_m(a)['source'] as String),
      )
      ..registerGlobal(
        'Future.value',
        (_, a) => Future<Object?>.value(_m(a)['value']),
      )
      ..registerGlobal(
        'Stream.fromIterable',
        (_, a) => Stream<Object?>.fromIterable(_m(a)['elements'] as Iterable),
      )
      // Exception/error constructors, so guest `throw Exception('...')` and the
      // like build real Dart objects that typed `catch` clauses can match.
      ..registerGlobal('Exception', (_, a) => Exception(_m(a)['message']))
      ..registerGlobal(
        'FormatException',
        (_, a) => FormatException((_m(a)['message'] ?? '') as String),
      )
      ..registerGlobal(
        'StateError',
        (_, a) => StateError((_m(a)['message'] ?? '') as String),
      )
      ..registerGlobal(
        'ArgumentError',
        (_, a) => ArgumentError(_m(a)['message']),
      )
      ..registerGlobal('RangeError', (_, a) => RangeError(_m(a)['message']))
      ..registerGlobal(
        'UnsupportedError',
        (_, a) => UnsupportedError((_m(a)['message'] ?? '') as String),
      )
      ..registerGlobal(
        'UnimplementedError',
        (_, a) => UnimplementedError(_m(a)['message'] as String?),
      )
      ..registerGlobal(
        'AssertionError',
        (_, a) => AssertionError(_m(a)['message']),
      )
      ..registerGlobal('Symbol', (_, a) => Symbol(_m(a)['name'] as String))
      // `dart:core` Duration — a value type, so it is core rather than a
      // framework concern (implicit animations and timeouts both take one).
      ..registerGlobal('Duration', (_, a) {
        final m = _m(a);
        return Duration(
          days: (m['days'] ?? 0) as int,
          hours: (m['hours'] ?? 0) as int,
          minutes: (m['minutes'] ?? 0) as int,
          seconds: (m['seconds'] ?? 0) as int,
          milliseconds: (m['milliseconds'] ?? 0) as int,
          microseconds: (m['microseconds'] ?? 0) as int,
        );
      })
      // `dart:convert` — pure computation, no I/O, so it crosses no sandbox
      // boundary. Patches that talk to a host-granted network capability need
      // it to make sense of the bytes.
      ..registerGlobal('jsonDecode', (_, a) => jsonDecode(a[0] as String))
      ..registerGlobal('jsonEncode', (_, a) => jsonEncode(a[0]))
      // Static getters/constants, keyed as `Type.member` (no arguments).
      ..registerGlobal('double.infinity', (_, _) => double.infinity)
      ..registerGlobal(
        'double.negativeInfinity',
        (_, _) => double.negativeInfinity,
      )
      ..registerGlobal('double.nan', (_, _) => double.nan)
      ..registerGlobal('double.maxFinite', (_, _) => double.maxFinite);
  }

  /// The `{parameterName: value}` argument map a host constructor/static call
  /// receives as its single argument.
  static Map<Object?, Object?> _m(List<Object?> args) =>
      args.isEmpty ? const {} : args[0] as Map<Object?, Object?>;

  static void _installObject(HostRegistry r) {
    r
      ..register('Object', 'toString', (x, _) => x.toString())
      ..register('Object', '==', (x, a) => x == a[0])
      ..register('Object', 'hashCode', (x, _) => x.hashCode)
      ..register('Object', 'runtimeType', (x, _) => x.runtimeType.toString())
      ..register('Null', 'toString', (x, _) => 'null');
  }

  static void _installString(HostRegistry r) {
    String s(Object? x) => x as String;
    r
      ..register('String', 'length', (x, _) => s(x).length)
      ..register('String', 'isEmpty', (x, _) => s(x).isEmpty)
      ..register('String', 'isNotEmpty', (x, _) => s(x).isNotEmpty)
      ..register('String', 'toUpperCase', (x, _) => s(x).toUpperCase())
      ..register('String', 'toLowerCase', (x, _) => s(x).toLowerCase())
      ..register('String', 'trim', (x, _) => s(x).trim())
      ..register('String', 'trimLeft', (x, _) => s(x).trimLeft())
      ..register('String', 'trimRight', (x, _) => s(x).trimRight())
      ..register(
        'String',
        'substring',
        (x, a) => a.length == 1
            ? s(x).substring(a[0] as int)
            : s(x).substring(a[0] as int, a[1] as int),
      )
      ..register('String', 'contains', (x, a) => s(x).contains(a[0] as Pattern))
      ..register(
        'String',
        'startsWith',
        (x, a) => s(x).startsWith(a[0] as Pattern),
      )
      ..register('String', 'endsWith', (x, a) => s(x).endsWith(a[0] as String))
      ..register('String', 'indexOf', (x, a) => s(x).indexOf(a[0] as Pattern))
      ..register(
        'String',
        'replaceAll',
        (x, a) => s(x).replaceAll(a[0] as Pattern, a[1] as String),
      )
      ..register('String', 'split', (x, a) => s(x).split(a[0] as Pattern))
      ..register('String', 'codeUnitAt', (x, a) => s(x).codeUnitAt(a[0] as int))
      ..register(
        'String',
        'compareTo',
        (x, a) => s(x).compareTo(a[0] as String),
      )
      ..register(
        'String',
        'padLeft',
        (x, a) =>
            s(x).padLeft(a[0] as int, a.length > 1 ? a[1] as String : ' '),
      )
      ..register(
        'String',
        'padRight',
        (x, a) =>
            s(x).padRight(a[0] as int, a.length > 1 ? a[1] as String : ' '),
      )
      ..register('String', '+', (x, a) => s(x) + (a[0] as String))
      ..register('String', '*', (x, a) => _repeat(s(x), a[0] as int))
      ..register('String', 'toString', (x, _) => x);
  }

  static void _installNum(HostRegistry r) {
    num n(Object? x) => x as num;
    r
      ..register('num', 'abs', (x, _) => n(x).abs())
      ..register('num', 'toDouble', (x, _) => n(x).toDouble())
      ..register('num', 'toInt', (x, _) => n(x).toInt())
      ..register('num', 'floor', (x, _) => n(x).floor())
      ..register('num', 'ceil', (x, _) => n(x).ceil())
      ..register('num', 'round', (x, _) => n(x).round())
      ..register('num', 'truncate', (x, _) => n(x).truncate())
      ..register('num', 'isNegative', (x, _) => n(x).isNegative)
      ..register('num', 'isFinite', (x, _) => n(x).isFinite)
      ..register('num', 'isNaN', (x, _) => n(x).isNaN)
      ..register('num', 'clamp', (x, a) => n(x).clamp(a[0] as num, a[1] as num))
      ..register('num', 'compareTo', (x, a) => n(x).compareTo(a[0] as num))
      ..register('num', 'toString', (x, _) => n(x).toString())
      ..register('num', '+', (x, a) => n(x) + (a[0] as num))
      ..register('num', '-', (x, a) => n(x) - (a[0] as num))
      ..register('num', '*', (x, a) => n(x) * (a[0] as num))
      ..register('num', '/', (x, a) => n(x) / (a[0] as num))
      ..register('num', '<', (x, a) => n(x) < (a[0] as num))
      ..register('num', '<=', (x, a) => n(x) <= (a[0] as num))
      ..register('num', '>', (x, a) => n(x) > (a[0] as num))
      ..register('num', '>=', (x, a) => n(x) >= (a[0] as num))
      ..register('num', 'unary-', (x, _) => -n(x))
      ..register('int', 'isEven', (x, _) => (x as int).isEven)
      ..register('int', 'isOdd', (x, _) => (x as int).isOdd)
      ..register('int', '&', (x, a) => (x as int) & (a[0] as int))
      ..register('int', '|', (x, a) => (x as int) | (a[0] as int))
      ..register('int', '^', (x, a) => (x as int) ^ (a[0] as int))
      ..register('int', '<<', (x, a) => (x as int) << (a[0] as int))
      ..register('int', '>>', (x, a) => (x as int) >> (a[0] as int))
      ..register('int', '~', (x, _) => ~(x as int))
      ..register(
        'int',
        'toRadixString',
        (x, a) => (x as int).toRadixString(a[0] as int),
      )
      ..register('int', 'gcd', (x, a) => (x as int).gcd(a[0] as int))
      ..register(
        'double',
        'toStringAsFixed',
        (x, a) => (x as double).toStringAsFixed(a[0] as int),
      );
  }

  static void _installBool(HostRegistry r) {
    r
      ..register('bool', 'toString', (x, _) => x.toString())
      ..register('bool', '&', (x, a) => (x as bool) & (a[0] as bool))
      ..register('bool', '|', (x, a) => (x as bool) | (a[0] as bool))
      ..register('bool', '^', (x, a) => (x as bool) ^ (a[0] as bool));
  }

  static void _installList(HostRegistry r) {
    List<Object?> l(Object? x) => x as List<Object?>;
    r
      ..register('List', 'length', (x, _) => l(x).length)
      ..register('List', 'isEmpty', (x, _) => l(x).isEmpty)
      ..register('List', 'isNotEmpty', (x, _) => l(x).isNotEmpty)
      ..register('List', 'add', (x, a) => l(x).add(a[0]))
      ..register('List', 'addAll', (x, a) => l(x).addAll(a[0] as Iterable))
      ..register('List', '[]', (x, a) => l(x)[a[0] as int])
      ..register('List', '[]=', (x, a) => l(x)[a[0] as int] = a[1])
      ..register('List', 'first', (x, _) => l(x).first)
      ..register('List', 'last', (x, _) => l(x).last)
      ..register('List', 'contains', (x, a) => l(x).contains(a[0]))
      ..register('List', 'indexOf', (x, a) => l(x).indexOf(a[0]))
      ..register('List', 'removeAt', (x, a) => l(x).removeAt(a[0] as int))
      ..register('List', 'removeLast', (x, _) => l(x).removeLast())
      ..register('List', 'remove', (x, a) => l(x).remove(a[0]))
      ..register('List', 'insert', (x, a) => l(x).insert(a[0] as int, a[1]))
      ..register('List', 'clear', (x, _) => l(x).clear())
      ..register('List', 'sort', (x, a) {
        if (a.isEmpty) return l(x).cast<Comparable>().sort();
        final f = a[0] as Function;
        return l(x).sort((p, q) => f(p, q) as int);
      })
      ..register(
        'List',
        'sublist',
        (x, a) => a.length == 1
            ? l(x).sublist(a[0] as int)
            : l(x).sublist(a[0] as int, a[1] as int),
      )
      ..register(
        'List',
        'join',
        (x, a) => l(x).join(a.isEmpty ? '' : a[0] as String),
      )
      ..register('List', 'reversed', (x, _) => l(x).reversed.toList())
      ..register('List', 'toList', (x, _) => l(x).toList())
      ..register('List', 'elementAt', (x, a) => l(x).elementAt(a[0] as int));
    _installHigherOrder(r, 'List');
  }

  /// Registers the closure-taking iterable methods for [kind]. The callback
  /// arrives already marshalled to a Dart [Function] (the interpreter converts
  /// an interpreted closure at the call boundary), so each method wraps it in a
  /// correctly-typed lambda and casts the result to what `dart:core` expects.
  /// Lazy results (`map`, `where`, `expand`) are materialized to a `List` so the
  /// interpreter always receives a concrete, re-iterable value.
  static void _installHigherOrder(HostRegistry r, String kind) {
    Iterable<Object?> it(Object? x) => x as Iterable<Object?>;
    r
      ..register(kind, 'map', (x, a) {
        final f = a[0] as Function;
        return it(x).map<Object?>((e) => f(e)).toList();
      })
      ..register(kind, 'where', (x, a) {
        final f = a[0] as Function;
        return it(x).where((e) => f(e) as bool).toList();
      })
      ..register(kind, 'forEach', (x, a) {
        final f = a[0] as Function;
        for (final e in it(x)) {
          f(e);
        }
        return null;
      })
      ..register(kind, 'any', (x, a) {
        final f = a[0] as Function;
        return it(x).any((e) => f(e) as bool);
      })
      ..register(kind, 'every', (x, a) {
        final f = a[0] as Function;
        return it(x).every((e) => f(e) as bool);
      })
      ..register(kind, 'expand', (x, a) {
        final f = a[0] as Function;
        return it(x).expand<Object?>((e) => f(e) as Iterable<Object?>).toList();
      })
      ..register(kind, 'fold', (x, a) {
        final f = a[1] as Function;
        return it(x).fold<Object?>(a[0], (acc, e) => f(acc, e));
      })
      ..register(kind, 'reduce', (x, a) {
        // A manual fold over the first element avoids `Iterable.reduce`, whose
        // combiner is reified to the concrete element type (e.g. `int`) and so
        // rejects the `Object?`-typed bridge callback.
        final f = a[0] as Function;
        final iter = it(x).iterator;
        if (!iter.moveNext()) {
          throw StateError('reduce of an empty collection');
        }
        var acc = iter.current;
        while (iter.moveNext()) {
          acc = f(acc, iter.current);
        }
        return acc;
      })
      ..register(kind, 'firstWhere', (x, a) {
        final f = a[0] as Function;
        // Optional named `orElse` arrives positionally after the test (the
        // compiler reorders named arguments into parameter order).
        final orElse = a.length > 1 ? a[1] as Function : null;
        return it(x).firstWhere(
          (e) => f(e) as bool,
          orElse: orElse == null ? null : () => orElse(),
        );
      })
      ..register(kind, 'takeWhile', (x, a) {
        final f = a[0] as Function;
        return it(x).takeWhile((e) => f(e) as bool).toList();
      })
      ..register(kind, 'skipWhile', (x, a) {
        final f = a[0] as Function;
        return it(x).skipWhile((e) => f(e) as bool).toList();
      });
  }

  static void _installMap(HostRegistry r) {
    Map<Object?, Object?> m(Object? x) => x as Map<Object?, Object?>;
    r
      ..register('Map', 'length', (x, _) => m(x).length)
      ..register('Map', 'isEmpty', (x, _) => m(x).isEmpty)
      ..register('Map', 'isNotEmpty', (x, _) => m(x).isNotEmpty)
      ..register('Map', '[]', (x, a) => m(x)[a[0]])
      ..register('Map', '[]=', (x, a) => m(x)[a[0]] = a[1])
      ..register('Map', 'containsKey', (x, a) => m(x).containsKey(a[0]))
      ..register('Map', 'containsValue', (x, a) => m(x).containsValue(a[0]))
      ..register('Map', 'keys', (x, _) => m(x).keys.toList())
      ..register('Map', 'values', (x, _) => m(x).values.toList())
      ..register('Map', 'remove', (x, a) => m(x).remove(a[0]))
      ..register('Map', 'clear', (x, _) => m(x).clear())
      ..register(
        'Map',
        'addAll',
        (x, a) => m(x).addAll(a[0] as Map<Object?, Object?>),
      );
  }

  static void _installSet(HostRegistry r) {
    Set<Object?> t(Object? x) => x as Set<Object?>;
    r
      ..register('Set', 'length', (x, _) => t(x).length)
      ..register('Set', 'isEmpty', (x, _) => t(x).isEmpty)
      ..register('Set', 'isNotEmpty', (x, _) => t(x).isNotEmpty)
      ..register('Set', 'add', (x, a) => t(x).add(a[0]))
      ..register('Set', 'remove', (x, a) => t(x).remove(a[0]))
      ..register('Set', 'contains', (x, a) => t(x).contains(a[0]))
      ..register('Set', 'clear', (x, _) => t(x).clear())
      ..register('Set', 'addAll', (x, a) => t(x).addAll(a[0] as Iterable))
      ..register('Set', 'toList', (x, _) => t(x).toList());
    _installHigherOrder(r, 'Set');
  }

  static void _installIterator(HostRegistry r) {
    r
      ..register('List', 'iterator', (x, _) => (x as Iterable).iterator)
      ..register('Set', 'iterator', (x, _) => (x as Iterable).iterator)
      ..register('Object', 'iterator', (x, _) => (x as Iterable).iterator)
      ..register('Iterator', 'moveNext', (x, _) => (x as Iterator).moveNext())
      ..register('Iterator', 'current', (x, _) => (x as Iterator).current)
      ..register('Object', 'moveNext', (x, _) => (x as Iterator).moveNext())
      ..register('Object', 'current', (x, _) => (x as Iterator).current);
  }
}
