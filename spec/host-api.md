# Ejenix Host-API Specification

**Status:** Draft · **Last updated:** 2026-07-12

This document defines the Ejenix host-API allow-list: the only surface through which
interpreted bytecode reaches the host Dart runtime. It is the interpreter's
sandbox boundary (brief §6.3). The reference registry is
`packages/interpreter/lib/src/host_api.dart`. RFC 2119 keywords apply.

---

## 1. Model

There is **no reflection** — `dart:mirrors` is forbidden — so interpreted code
cannot discover or invoke host members on its own. Every dynamic method call
(`invoke.dyn`) and every host global (`invoke.static`) resolves against an
explicit registry:

- **Methods** are keyed by a coarse receiver *kind* and a selector name. A
  getter is a zero-argument selector; an operator is its symbolic selector
  (`+`, `[]`, `[]=`, `<`, `unary-`, …).
- **Globals** are receiver-less functions keyed by name (`print`, `identical`).

Resolution walks a **kind chain** from most specific to the `Object` fallback,
giving inheritance-like behavior:

| Receiver     | Kind chain                    |
| ------------ | ----------------------------- |
| `int`        | `int` → `num` → `Object`      |
| `double`     | `double` → `num` → `Object`   |
| `String`     | `String` → `Object`           |
| `List`       | `List` → `Object`             |
| `Set`        | `Set` → `Object`              |
| `Map`        | `Map` → `Object`              |
| `bool`       | `bool` → `Object`             |
| `null`       | `Null` → `Object`             |
| host iterator| `Iterator` → `Object`         |

A selector not found on any kind in the chain is a typed runtime fault
(`no host method '<sel>' on <Type>`), never silent. An embedder MAY start from
an empty [HostRegistry] and register only what a given deployment permits —
tightening the sandbox further than the default.

---

## 2. Default allow-list

`HostRegistry.standard()` installs the following `dart:core` subset. This is the
capability set ordinary patch code relies on; it deliberately excludes IO,
FFI, isolates, and reflection.

### Object (all non-null receivers; `Null` where noted)
`toString`, `==`, `hashCode`, `runtimeType` (as a string).

### String
`length`, `isEmpty`, `isNotEmpty`, `toUpperCase`, `toLowerCase`, `trim`,
`trimLeft`, `trimRight`, `substring`, `contains`, `startsWith`, `endsWith`,
`indexOf`, `replaceAll`, `split`, `codeUnitAt`, `compareTo`, `padLeft`,
`padRight`, `+`, `*`.

### num (int and double)
`abs`, `toDouble`, `toInt`, `floor`, `ceil`, `round`, `truncate`, `isNegative`,
`isFinite`, `isNaN`, `clamp`, `compareTo`, `+`, `-`, `*`, `/`, `<`, `<=`, `>`,
`>=`, `unary-`.

### int
`isEven`, `isOdd`, `toRadixString`, `gcd`, and the bitwise/shift operators `&`,
`|`, `^`, `<<`, `>>`, `~`.

### double
`toStringAsFixed`.

### bool
`toString`, `&`, `|`, `^`.

### List
`length`, `isEmpty`, `isNotEmpty`, `add`, `addAll`, `[]`, `[]=`, `first`,
`last`, `contains`, `indexOf`, `removeAt`, `removeLast`, `remove`, `insert`,
`clear`, `sort` (natural order or with a comparator), `sublist`, `join`,
`reversed`, `toList`, `elementAt`, `iterator`, and the higher-order methods
below.

### Map
`length`, `isEmpty`, `isNotEmpty`, `[]`, `[]=`, `containsKey`, `containsValue`,
`keys`, `values`, `remove`, `clear`.

### Set
`length`, `isEmpty`, `isNotEmpty`, `add`, `remove`, `contains`, `clear`,
`toList`, `iterator`, and the higher-order methods below.

### Higher-order methods (List and Set)
`map`, `where`, `forEach`, `any`, `every`, `expand`, `fold`, `reduce`,
`firstWhere`, `takeWhile`, `skipWhile`. Each takes an interpreted closure, which
the interpreter marshals to a real Dart callback at the call boundary
(`_dartAdapter`, arities 0–3) so it can re-enter the VM. Lazy results (`map`,
`where`, `expand`) are materialized to a `List` so callers always receive a
concrete, re-iterable value.

### Iterator (for `for-in`)
`moveNext`, `current`.

### Duration
`inDays`, `inHours`, `inMinutes`, `inSeconds`, `inMilliseconds`,
`inMicroseconds`, `+`, `-`, `*`, `<`, `>`. A value type, so it is `dart:core`
rather than a framework concern — an implicit animation and a timeout are both
expressed in one.

### Globals
`print`, `identical`; the exception and error constructors (`Exception`,
`FormatException`, `StateError`, `ArgumentError`, `RangeError`,
`UnsupportedError`, `UnimplementedError`, `AssertionError`); `Symbol`;
`Duration`; `jsonDecode` / `jsonEncode`; `Future.value`;
`Stream.fromIterable`; `int.parse` / `int.tryParse`, `double.parse` /
`double.tryParse`; the `dart:math` functions (`min`, `max`, `sqrt`, `pow`,
`sin`, `cos`, `tan`, `log`, `exp`); and the `double` constants (`infinity`,
`negativeInfinity`, `nan`, `maxFinite`).

`dart:convert`'s `jsonDecode`/`jsonEncode` are in the default list because they
are **pure computation**: they touch no I/O and cross no boundary. A patch that
is granted a network capability needs them to make sense of the bytes.

---

## 3. Excluded, and why

The following are **not** in the default allow-list:

- **`dart:ffi`, `dart:isolate`, `dart:mirrors`** — permanently forbidden, and
  rejected at compile time with code `E0200` (brief §6.2, §6.3). They would each
  bypass this allow-list entirely, which is the whole sandbox. See
  `docs/errors/E0200.md`.
- **`dart:io` and the network** — not reachable by default. Platform effects
  reach a patch only through capabilities the embedder chooses to register. The
  Flutter bridge ships an *opt-in* HTTP capability
  (`flutter_bridge/lib/ejenix_flutter_http.dart`) that must be both imported and
  explicitly enabled, and even then is bounded to HTTPS on a host allow-list.
  The stricter, preferred pattern is to expose the *specific* call a patch
  needs — `registry.registerGlobal('api.loadTodos', …)` — which keeps the URL,
  auth, and retry policy in the shipped binary.
- **Raw platform channels** — same reason. Surface a named capability instead.

---

## 4. Determinism and safety

- The registry is fixed per interpreter instance; resolution is a pure function
  of receiver kind and selector.
- A host method receives already-evaluated argument values. It re-enters
  interpreted code only when the program passed it a closure (the bridge marshals
  that closure to a Dart callback); re-entry runs synchronously on the same
  interpreter and is bounded by the same call-depth limit.
- Faults are typed `InterpreterException`s and carry the bytecode program
  counter for debugging.

---

## 5. Extending

To expose an app-specific capability (e.g. a design-token lookup or a framework
call), the embedder registers it before running a bundle:

```dart
final registry = HostRegistry.standard()
  ..registerGlobal('themeColor', (_, args) => lookupColor(args[0] as String));
final interpreter = Interpreter(module, hostRegistry: registry);
```

The compiler's type-safe host bindings (brief §6.10) are generated from this
document so a developer cannot call a capability that is not on the list.

---

Part of **[Ejenix](https://github.com/ejenix/opensource)** — an open-source,
interpreter-based live-update stack for Flutter. See the
[project README](../README.md) for an overview, and
[`docs/production.md`](../docs/production.md) for running Ejenix in production.
