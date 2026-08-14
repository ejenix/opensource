# Ejenix Dart Subset Specification

**Status:** Draft · **Last updated:** 2026-07-13

This document defines the subset of Dart the Ejenix compiler (`packages/compiler/`)
accepts and how it lowers to bytecode. Source outside the subset is rejected
with a located, actionable diagnostic — never mis-compiled. The compiler is
deterministic: identical source and compiler version yield byte-identical
modules (`spec/bytecode.md` §6).

The subset grows in milestones. Each milestone keeps the whole toolchain in
lockstep — every construct listed as *supported* compiles, runs, and is tested.
Constructs listed as *planned* are rejected today with a diagnostic that names
them, so no program is ever silently miscompiled.

---

## 1. Frontend

Source is parsed and resolved by `package:analyzer` (brief §4.1, §6.2), which
provides the syntax tree and full static types. Any analyzer error (syntax or
resolution) is reported and stops compilation before lowering. Type information
drives typed-opcode selection, so the interpreter never dispatches on operand
type at runtime.

---

## 2. Supported today

Milestone 2a added dynamic dispatch through the host-API bridge
(`spec/host-api.md`), which unlocks methods, strings, and collections.
Milestone 2b added user-defined classes: fields, constructors, methods,
getters, and single inheritance with virtual dispatch; closures: function
expressions, local functions, capture by reference, and higher-order collection
methods; and `async`/`await`: `Future`-returning functions driven on the host
event loop.

### Program structure
- Top-level functions, methods, and constructors with **required positional,
  optional positional, and named parameters, including default values**
  (`f(a, [b = 1])`, `f({a, b = 2})`, `f({required a})`). Named and optional
  arguments to functions and constructors defined in the unit are supported;
  named arguments on instance methods are a follow-up.
- Block bodies (`{ … }`) and expression bodies (`=> …`).
- Direct and mutual recursion; calls between top-level functions in the unit.
- The entry point is a function named `main`.

Optional/named parameters are lowered at compile time: the caller places one
value per parameter in declaration order, emitting the absent-argument sentinel
(`load.undef`) for any it omits, and the callee's prologue substitutes each
missing parameter's default. This keeps the calling convention purely
positional and the interpreter unaware of named parameters.

### Types
- `int`, `double`, `bool`, `String`, and `Null` values.
- Static types select typed opcodes: `int` arithmetic uses `.i` opcodes,
  `double` uses `.d`, and mixed operands widen the `int` side with `i2d`.

### Expressions
- Integer, double, boolean, string, and null literals. Integer literals outside
  the 16-bit immediate range are interned in the constant pool.
- Arithmetic: `+`, `-`, `*`, `/`, `~/`, `%`, unary `-`. Concrete `int`/`double`
  use typed opcodes; `num`-typed and other operands dispatch through the host
  bridge. `/` is always `double`-valued (Dart semantics).
- Relational and equality: `<`, `<=`, `>`, `>=`, `==`, `!=`.
- Bitwise and shift on `int`: `&`, `|`, `^`, `<<`, `>>`, `~`.
- Logical `&&`, `||` (short-circuit) and `!`.
- Null-aware: `??`, `??=`, `?.`, and the `!` assertion.
- Conditional `c ? a : b`.
- Increment/decrement `++`/`--`, prefix and postfix.
- **Type tests and casts**: `e is T`, `e is! T`, and `e as T`. Core types,
  user-class chains (with nullability suffixes), and the common exception/error
  hierarchy (`Exception`, `Error`, `FormatException`, `StateError`, …) test
  exactly; a failed `as` raises a typed fault.
- **`switch` expressions** (`switch (x) { 1 => a, _ => b }`) over constant and
  wildcard patterns.
- **`throw`** as an expression (type `Never`) and **`rethrow`** inside a catch
  clause.
- **String interpolation** (`'$x and ${a + b}'`) and adjacent-string
  concatenation.
- **Collection literals**: `List`, `Map`, and `Set` (including typed empty
  literals), with indexing `[]`/`[]=`, and **spread** (`...`, `...?`),
  **collection-`if`** (with `else`), and **collection-`for`** (C-style and
  `for-in`) elements.
- **Records**: literals `(a, b)` and `(x: a, y: b)` (positional, named, or
  mixed) and field access `r.$1`, `r.$2`, `r.name`. Records compare by
  structural equality and render as `(1, 2, name: x)`.
- **Instance method calls and getters** on values (`s.toUpperCase()`,
  `xs.length`, `m['k']`), dispatched dynamically through the host allow-list.
- Calls to top-level functions in the unit, and to host globals such as
  `print`, `min`, `max`, `sqrt`.
- **Static method calls** (`int.parse`, `double.tryParse`) and **out-of-unit
  construction** (`Future.value(x)`), which dispatch to a host global named
  `Type.method` / `Type` / `Type.namedConstructor`, validated against the
  allow-list at runtime — the same boundary as host method calls, and the hook a
  Flutter bridge registers against. (Static getters/fields such as
  `double.infinity` are a follow-up.)
- Parenthesized expressions.

### Statements
- Local variable declarations (`var`, `final`, typed), with block scoping.
- **Record destructuring** in a declaration — `var (a, b) = pair;` and named
  `var (x: a, y: b) = point;` — binding each field to a new local. (Only record
  patterns of simple variables; list/map/object patterns and nested subpatterns
  are reported.)
- Assignment `=`, compound (`+=`, `-=`, `*=`, `/=`, `%=`), and `??=` to locals,
  parameters, **fields** (`o.f += 1`), and **indexed targets** (`xs[i] += 1`).
- **Cascades** (`o..a()..b = v`) — the receiver is evaluated once.
- `if` / `else`.
- `while` and `do`/`while`.
- C-style `for` and `for-in` (over any host-iterable via the Iterator protocol).
- **`switch`** statements and expressions over constant *and* structural
  patterns (see *Patterns*), with `default`, `when` guards, and fall-through of
  empty cases.
- **`try` / `catch` / `finally`** — see *Error handling* below.
- **`assert(cond[, msg])`** (a satisfied assertion is a no-op; a failed one
  throws `AssertionError`).
- `break` and `continue`, including labeled (`break outer;`) targeting an outer
  loop or labeled block.
- `return` (with or without a value); nested blocks; empty statements.

### Error handling
- **`throw e`** raises any value; an uncaught throw escapes the entry point as
  `InterpreterUncaughtException` carrying the thrown value.
- **`try` / `on T catch (e, st)` / `catch (e)` / `finally`**, with multiple
  clauses tried in order, an optional type guard per clause, and `rethrow`.
  Typed clauses match core types, user classes, and the built-in
  exception/error hierarchy; a Dart exception raised by a host call (e.g.
  `int.parse` on bad input) is catchable as the real object.
- **`finally` runs on every exit** — normal completion, a caught or re-raised
  exception, and any `return`/`break`/`continue` that leaves the protected
  region. `throw Exception('…')`, `FormatException`, `StateError`, and the other
  common constructors build real Dart objects.
- Interpreter *faults* (sandbox-limit violations, failed casts, division by
  zero, dispatch errors) are VM-level and propagate **past** guest `catch`; they
  are not guest-catchable. Handlers are serialized per function as an
  exception-handler table (body format v6, `spec/bundle.md` §6.4).

### Classes and objects
- **Class declarations** with instance fields (typed, `late`, or with a
  declaration initializer) and a `const []`-free single superclass (`extends`).
- **Constructors**: field-formal parameters (`this.x`), initializer-list field
  initializers (`: x = e`), a redirecting-free super call (`: super(a)`), and a
  constructor body. Every field occupies a disjoint slot, so initialization is
  order-independent. An implicit `super()` runs when no explicit one is written.
- **Methods and getters**, including calls to other members through the implicit
  receiver (`this` is optional and may also be written explicitly, including as
  a first-class value).
- **Instance creation** (`Point(3, 4)`), field get/set through a receiver
  (`p.x`, `p.x = v`), and objects stored in collections.
- **Virtual dispatch**: an inherited method that calls an overridden one resolves
  to the runtime type's override. Fields the compiler can prove are stored emit
  direct `load.field`/`store.field`; everything else dispatches dynamically
  through the same inline-cache path as host types (`spec/host-api.md`).
- **Enums**: plain `enum` declarations, their constant members (`Color.red`),
  and `.index`/`.name`/`toString()`. Values compare by `(enum, index)` and are
  interned in the constant pool.

Classes are serialized in the bundle body as a class table (body format v3,
`spec/bundle.md` §6.4): name, field count, superclass index, and flattened
method/field slot maps, topologically ordered so each superclass precedes its
subclasses.

### Closures and functions as values
- **Function expressions** (`(x) => …`, `(x) { … }`) and **local function
  declarations** (`int f(int x) => …;`), including recursion.
- **Capture by reference**: a closure and its enclosing scope share one mutable
  location for each captured variable. The compiler boxes exactly the
  locals/parameters a nested closure reads or writes into heap *cells*
  (`cell.new`/`cell.get`/`cell.set`); everything else stays in registers. A
  closure records its free variables as upvalues and grabs their cells at
  `closure.new` time, so a returned closure keeps working after the defining
  frame is gone.
- **Calling** a closure value (`f(args)`) and immediately-invoked function
  expressions, through the same polymorphic `call` opcode as top-level
  functions.
- **Higher-order collection methods** — `map`, `where`, `forEach`, `any`,
  `every`, `fold`, `reduce`, `expand`, `firstWhere`, `takeWhile`, `skipWhile`,
  and `sort` with a comparator — by passing an interpreted closure to the host
  method, which the bridge marshals to a real Dart callback (`spec/host-api.md`).

Each function's capture list is serialized in the bundle body (body format v4,
`spec/bundle.md` §6.4). A closure may also **capture `this`** — reading or
writing instance fields and calling instance methods through an implicit
receiver — which the compiler threads through as an upvalue, so callbacks passed
to the framework (e.g. a button's `onPressed` mutating a field) work.

### Asynchrony
- **`async` functions**, methods, and closures — anything marked `async`. They
  return a `Future`, and the compiler records the `isAsync` flag on the function
  (body format v5, `spec/bundle.md` §6.4).
- **`await`** on any `Future` — one produced by another interpreted `async`
  function or returned by a registered host capability. Awaiting a non-`Future`
  yields the value unchanged (Dart semantics).
- `await` works anywhere an expression does, including inside loops and
  conditionals; the interpreter suspends and resumes across each one.

The interpreter runs an `async` function on the **host event loop**: it executes
synchronously until it awaits an unresolved future, suspends there (saving the
frame), and resumes when the future completes. Sync code keeps running through
the fast synchronous dispatch path — only `async` functions pay for suspension.
Call an `async` entry point with `Interpreter.runAsync` /
`callFunctionAsync`; calling one synchronously is a typed error.

**Generators** (`sync*`/`async*` with `yield`/`yield*`) and **`await for`** are
**lazy**: calling a `sync*` function returns a lazy `Iterable` (an `async*` a
`Stream`) whose body runs one `yield` at a time, driven by a coroutine-style
suspension (`yield` opcode). An infinite generator therefore terminates when
consumed finitely (`nats().take(5)`, `firstWhere`). `await for` iterates a
stream. `await` inside a generator body is reported rather than mis-lowered.

### Static members, operators, and constructors
- **Static methods and fields**: `C.f(…)` calls a plain function; `C.x`
  reads/writes a module global initialized once by a static initializer before
  the entry point.
- **Operator overloading**: `+`, `-`, `[]`, `[]=`, `==`, `<`, unary `-`, … as
  instance methods. `a == b` on a user type dispatches to the override, falling
  back to identity when a class declares none.
- **All constructor forms**: named (`C.at(…)`), factory (returning any instance),
  redirecting (`C.zero() : this(0)`), `const`, and `super.x` forwarding formals.

### Generics, mixins, and extensions
- **User generics** — generic classes, methods, and functions (`Box<T>`,
  `T first<T>(List<T>)`) — are accepted and **type-erased**: type arguments do
  not exist at runtime, matching the interpreter's dynamic value model.
- **Mixins** (`mixin M { … }`, `class C with M1, M2`) are linearized into each
  applying class: a mixin's methods and fields are compiled fresh against the
  host class's layout, so field slots and `this`-dispatch resolve correctly. A
  later declaration (the class, or a rightward mixin) overrides an earlier one.
- **Extension methods and getters** (`extension E on T { … }`) dispatch
  statically to a function that takes the receiver as `this`.

### Patterns
- **Declaration destructuring** (`var [a, b] = …;`, `var (x: a) = …;`) and
  **pattern `switch`** statements and expressions, with **`when` guards**.
- Pattern forms: variable, wildcard (`_`), constant, **list** (with a `...`
  rest), **map**, **record**, **object** (`Point(x: var a)`), **relational**
  (`> 5`), **logical** (`&&`, `||`), cast (`as T`), null-check (`?`), and
  null-assert (`!`), including arbitrary nesting.
- **`if`-case** (`if (e case Pattern when g) …`).

### Other language features
- **Tear-offs**: top-level, static, local, and instance-method references used
  as values (an instance tear-off captures its receiver as a bound closure).
- **Named/optional arguments on instance methods** declared in this unit
  (reordered into parameter slots, defaults filled by the callee prologue).
- **`assert(cond[, msg])`**, **labeled `break`/`continue`** (and labeled
  blocks), **`throw`/`try`/`catch`/`finally`/`rethrow`** (see *Error handling*).
- **`Type` literals** (represented by the type's name, so `x.runtimeType == T`
  holds for core types) and **`Symbol` literals** (`#foo`, real `dart:core`
  Symbols).

### Register model
Parameters occupy the lowest registers; locals are reserved within their block
scope; temporaries are allocated above live locals and freed at each statement
boundary. A function's register count is its high-water mark. See
`spec/bytecode.md` §4.2.

---

## 3. Planned (rejected today with a diagnostic)

The subset now spans essentially the whole language. `static` methods and
fields, operator overloading (including `==` with an identity fallback), every
constructor form (named, factory, redirecting factory `C() = D`, `const`, and
`super.x` forwarding formals), `typedef`s, `implements`, `extension type`
declarations, `external` members (dispatched to the host), explicit
`super.member` access, generic-function instantiation as a value (`f<int>`), and
named/optional arguments on host methods all ship. Generators are **lazy**: a
`sync*` returns a lazy `Iterable` and an `async*` a `Stream`, so an infinite
generator consumed with `take`/`firstWhere` terminates, and an `async*` body may
`await` between yields.

The following are still recognized and reported as *not yet supported* with a
source location, so intent is never mis-lowered:

- **Top-level variables** (a top-level `int x = 0;` — use a `static` field or a
  getter instead).
- Skipping an **optional host-method argument before a named one** (a positional
  gap in a host call).

Explicitly and permanently out of scope (compile-time error code `E0200` with a
suggestion, per brief §6.2): `dart:ffi`, `dart:mirrors`, `dart:isolate`, and raw
platform channels — cross the sandbox boundary through host capabilities
instead.

---

## 4. Diagnostics

Every diagnostic carries `path:line:column`, a plain-language message, and —
where applicable — a correction and a stable `E####` code indexing
`docs/errors/`. The quality bar is the Elm and Rust compilers (brief §6.2):
no cryptic messages. Analyzer-surfaced errors use code `E0000`; unsupported-
subset errors use `E0100` (expressions/statements) and `E0101` (top-level
declarations); sandbox-forbidden imports use `E0200`. Every code is documented,
one file per code, in [`docs/errors/`](../docs/errors/).

---

## 5. Optimizations

Lowering applies optimizations that never change observable behavior:

- **Constant folding.** A subexpression built only from literals and supported
  operators is evaluated at compile time and emitted as a single load
  (`2 + 3 * 4` → `load.int 14`). Each operator is folded with the *same* Dart
  operator the interpreter applies, so the result is bit-identical to executing
  the opcodes. An operation that would fault at runtime (`~/ 0`, `% 0`) is left
  unfolded so the VM still reproduces the fault, keeping semantics exact.

Planned: peephole redundant-move elimination (visible in disassembly),
dead-code elimination, tail-call and small-function inlining.

---

## 6. Determinism

Lowering is a pure function of the resolved unit: functions are indexed in
source order, constants are pooled in first-use order, and no map iteration or
wall-clock value influences emitted bytes. Constant folding is itself
deterministic (a pure function of the operand literals). The golden tests in
`packages/compiler/test/golden/` pin the exact output.

---

Part of **[Ejenix](https://github.com/ejenix/opensource)** — an open-source,
interpreter-based live-update stack for Flutter. See the
[project README](../README.md) for an overview, and
[`docs/production.md`](../docs/production.md) for running Ejenix in production.
