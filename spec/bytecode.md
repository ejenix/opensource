# Ejenix Bytecode Specification

**Status:** Draft · **Format version:** 1.0 · **Last updated:** 2026-07-12

This document normatively defines the Ejenix bytecode: its
value model, encoding, containers (constant pool, function prototype, module),
and the semantics of every instruction. A reader can implement a conforming
interpreter from this document alone. The reference encoder, decoder,
assembler, and disassembler live in `packages/bytecode/`.

The keywords **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are used as in
RFC 2119.

---

## 1. Design

The instruction set is **register-based**: operands name slots in a per-call
register file rather than positions on an operand stack. Under threaded
dispatch a register machine retires the same computation in fewer executed
instructions than a stack machine, because it avoids the explicit push/pop
traffic that dominates stack-VM dispatch. This is the central result of Ertl &
Gregg, *"The Structure and Performance of Efficient Interpreters"* (2003), and
it is why register VMs (e.g. Lua 5.x) outperform stack VMs under interpretation.

Design invariants:

- **Fixed-width instructions.** Every instruction is exactly one 32-bit word,
  making the fetch step branch-free and the code stream trivially indexable by
  word offset.
- **Stable encoding.** An opcode's wire value never changes once shipped
  (§5). The same source compiled by the same compiler version MUST produce
  byte-identical code (determinism, brief §10.4).
- **Total decoding.** Every 32-bit word either decodes to a defined opcode with
  well-formed operands or is rejected. There is no undefined behavior.

---

## 2. Value model

Runtime values are the Dart values the interpreter manipulates. The bytecode
itself only encodes the **literal constant** subset in the constant pool:

| Kind     | Notes                                                        |
| -------- | ----------------------------------------------------------- |
| `Null`   | the single value `null`                                     |
| `bool`   | `true` / `false`                                            |
| `int`    | 64-bit two's-complement (Dart `int`)                        |
| `double` | IEEE-754 binary64 (Dart `double`)                           |
| `String` | UTF-16 code units (Dart `String`), interned in the pool     |

Typed arithmetic and comparison opcodes (suffixed `.i` / `.d`) require operands of
the corresponding kind; behavior on a mismatch is a typed runtime error, never
silent coercion. Object, closure, collection, and exception values are produced
at runtime by their respective opcodes and are specified in `spec/*` as those
opcode groups land.

---

## 3. Instruction encoding

An instruction is a little-endian 32-bit word laid out by field:

```text
  bits 31..24   23..16    15..8     7..0
       C          B         A       opcode
```

`opcode` is the 8-bit code from §5. The three operand bytes A, B, C are
interpreted per the opcode's **operand format**:

| Format  | Reads                             | Used by                          |
| ------- | --------------------------------- | -------------------------------- |
| `none`  | —                                 | `ret.void`                       |
| `a`     | register A                        | `ret`, `load.null/true/false`    |
| `ab`    | registers A, B                    | `move`, `neg.*`, `not`           |
| `abc`   | registers A, B, C                 | arithmetic, comparison, `call`   |
| `aBx`   | register A, unsigned `Bx = B\|C<<8`| `load.const`, `load.func`        |
| `aSbx`  | register A, signed `sBx`          | `jz`, `jnz`                      |
| `sAx`   | signed `sAx = A\|B<<8\|C<<16`      | `jmp`, `pfx`                     |

`sBx` and `sAx` are two's-complement. Jump displacements are measured in
**instruction words**, relative to the instruction **following** the jump:
after fetching a jump at word *p*, the program counter is *p+1*, and the target
is *p+1+displacement*.

Operand ranges:

- register index: `0 … 255`
- `Bx` (unextended): `0 … 65535`
- `sBx`: `-32768 … 32767`
- `sAx`: `-8388608 … 8388607`

### 3.1 Wide-mode prefix (`pfx`)

When an `aBx` index exceeds 16 bits, it is encoded as a `pfx` instruction
immediately followed by the `aBx` instruction. `pfx` carries a 24-bit unsigned
payload in its `sAx` field; the effective index is:

```text
  index = (pfx_payload << 16) | Bx
```

giving indices up to 40 bits. A conforming decoder MUST, on encountering `pfx`,
read the following word, require it to be an `aBx`-format instruction, and apply
the extension. `pfx` MUST NOT appear other than immediately before an
`aBx`-format instruction, and MUST NOT be a branch target on its own — a branch
targets the `pfx` word so the logical instruction executes in full. The
reference assembler emits `pfx` automatically and never otherwise.

Jumps never require `pfx`: `jmp` uses the 24-bit `sAx` range directly, and a
conditional branch beyond `sBx` range is expressed as `jz`/`jnz` over a `jmp`.

---

## 4. Containers

### 4.1 Constant pool

A per-module, indexed table of literal constants (§2). Equal constants of the
same kind share one index — strings are interned, numbers deduplicated.
Deduplication is **type-aware**: `1` (`int`) and `1.0` (`double`) are `==` in
Dart yet occupy distinct slots, because the interpreter recovers the original
type from the slot. Doubles are deduplicated by their exact 64-bit pattern, so
`-0.0` and `0.0` are distinct and bitwise-equal `NaN`s coalesce.

### 4.2 Function prototype

A compiled function is
`{ name, paramCount, registerCount, code, captures, isAsync, handlers }`.
The interpreter allocates a register file of exactly `registerCount` slots per
activation; `registerCount ≥ paramCount` MUST hold. On entry the `paramCount`
positional arguments occupy `R[0] … R[paramCount-1]`; remaining registers are
locals and temporaries. Locals never spill to the heap. `captures` is empty for
an ordinary function; for a closure it lists the *defining* frame's registers
(each holding a cell) that `closure.new` grabs as upvalues, in upvalue order.
`isAsync` marks a function that returns a `Future` and may `await`; the runtime
invokes it on the event loop rather than inline. `handlers` is the
exception-handler table (empty when the function has no `try`): each entry is a
half-open `[start, end)` range of code-word offsets, a `target` offset, and a
catch register; on a `throw` (0x83) or propagating fault within a covered range
the runtime places the raised value in the catch register and jumps to `target`.
Entries are tried in order, so an inner region precedes the outer region that
encloses it. `finally` blocks lower to catch-all handlers whose target re-raises
after running the block.

### 4.3 Module

A module is `{ constants, functions, callSites, classes, entryFunction }`: the
shared constant pool, the function table (indexed by `load.func` and by `call`
targets), the dynamic-dispatch call-site table (indexed by `invoke.dyn` /
`invoke.static`), the class table (indexed by `alloc`), and the index of the
entry point in `functions` (or `-1` for a library module). Its serialized,
signed form is the bundle (`spec/bundle.md`).

---

## 5. Opcode reference

`code` is the permanent 8-bit wire value. `R[x]` denotes register *x* of the
current frame; `K[x]` the constant at pool index *x*; `F[x]` function *x* of the
module.

### Constants and moves

| code | mnemonic     | fmt   | effect                                             |
| ---- | ------------ | ----- | -------------------------------------------------- |
| 0x00 | `load.const` | aBx   | `R[A] = K[Bx]`                                      |
| 0x01 | `load.null`  | a     | `R[A] = null`                                      |
| 0x02 | `load.true`  | a     | `R[A] = true`                                      |
| 0x03 | `load.false` | a     | `R[A] = false`                                     |
| 0x04 | `load.int`   | aSbx  | `R[A] = sBx` (small integer immediate)             |
| 0x05 | `move`       | ab    | `R[A] = R[B]`                                       |
| 0x06 | `load.func`  | aBx   | `R[A] =` callable for `F[Bx]` (no captured env)     |
| 0x07 | `load.undef` | a     | `R[A] =` the absent-argument sentinel (omitted optional) |

### Integer arithmetic (operands MUST be `int`)

| code | mnemonic | fmt | effect                                              |
| ---- | -------- | --- | --------------------------------------------------- |
| 0x10 | `add.i`  | abc | `R[A] = R[B] + R[C]`                                 |
| 0x11 | `sub.i`  | abc | `R[A] = R[B] - R[C]`                                 |
| 0x12 | `mul.i`  | abc | `R[A] = R[B] * R[C]`                                 |
| 0x13 | `div.i`  | abc | `R[A] = R[B] ~/ R[C]`; `R[C]==0` throws             |
| 0x14 | `mod.i`  | abc | `R[A] = R[B] % R[C]` (result sign of divisor)       |
| 0x15 | `neg.i`  | ab  | `R[A] = -R[B]`                                       |

### Double arithmetic (operands MUST be `double`)

| code | mnemonic | fmt | effect               |
| ---- | -------- | --- | -------------------- |
| 0x20 | `add.d`  | abc | `R[A] = R[B] + R[C]` |
| 0x21 | `sub.d`  | abc | `R[A] = R[B] - R[C]` |
| 0x22 | `mul.d`  | abc | `R[A] = R[B] * R[C]` |
| 0x23 | `div.d`  | abc | `R[A] = R[B] / R[C]` |
| 0x24 | `mod.d`  | abc | `R[A] = R[B] % R[C]` |
| 0x25 | `neg.d`  | ab  | `R[A] = -R[B]`       |
| 0x26 | `i2d`    | ab  | `R[A] = (R[B] as int).toDouble()` |

### Comparison (result is a `bool` in `R[A]`)

| code | mnemonic | fmt | effect                    |
| ---- | -------- | --- | ------------------------- |
| 0x30 | `lt.i`   | abc | `R[A] = R[B] <  R[C]` int |
| 0x31 | `le.i`   | abc | `R[A] = R[B] <= R[C]` int |
| 0x32 | `gt.i`   | abc | `R[A] = R[B] >  R[C]` int |
| 0x33 | `ge.i`   | abc | `R[A] = R[B] >= R[C]` int |
| 0x34 | `eq.i`   | abc | `R[A] = R[B] == R[C]` int |
| 0x35 | `ne.i`   | abc | `R[A] = R[B] != R[C]` int |
| 0x36 | `lt.d`   | abc | double `<`                |
| 0x37 | `le.d`   | abc | double `<=`               |
| 0x38 | `gt.d`   | abc | double `>`                |
| 0x39 | `ge.d`   | abc | double `>=`               |
| 0x3A | `eq`     | abc | Dart structural `==`      |
| 0x3B | `ne`     | abc | Dart structural `!=`      |

### Logical and control flow

| code | mnemonic | fmt  | effect                                        |
| ---- | -------- | ---- | --------------------------------------------- |
| 0x40 | `not`    | ab   | `R[A] = !R[B]` (bool)                          |
| 0x41 | `jmp`    | sAx  | `pc += sAx`                                    |
| 0x42 | `jz`     | aSbx | if `R[A] == false`: `pc += sBx`               |
| 0x43 | `jnz`    | aSbx | if `R[A] == true`: `pc += sBx`                |

`jz`/`jnz` require `R[A]` to be a `bool`; a non-bool is a typed runtime error
(there is no truthiness coercion, consistent with Dart).

### Calls and returns

| code | mnemonic   | fmt | effect                                                   |
| ---- | ---------- | --- | -------------------------------------------------------- |
| 0x50 | `call`     | abc | call `R[A]` with `C` args in `R[A+1..A+C]`; result → R[A] |
| 0x51 | `ret`      | a   | return `R[A]` to the caller                              |
| 0x52 | `ret.void` | none| return `null` to the caller                             |

The callee in `R[A]` MUST be a callable — a function reference (`load.func`) or
a closure (`closure.new`) — whose arity matches `C`. Arguments are passed by
value in consecutive registers starting at `R[A+1]`.

### Dynamic dispatch, objects, and collections

| code | mnemonic        | fmt | effect                                                        |
| ---- | --------------- | --- | ------------------------------------------------------------- |
| 0x60 | `invoke.dyn`    | aBx | dispatch `callSites[Bx]` on receiver `R[A]`, args `R[A+1..]`; result → R[A] |
| 0x61 | `list.new`      | a   | `R[A] = <Object?>[]`                                           |
| 0x62 | `map.new`       | a   | `R[A] = <Object?, Object?>{}`                                 |
| 0x63 | `set.new`       | a   | `R[A] = <Object?>{}`                                          |
| 0x64 | `invoke.static` | aBx | call host global `callSites[Bx]` with args `R[A..]`; result → R[A] |
| 0x65 | `alloc`         | aBx | `R[A] =` fresh instance of `classes[Bx]` (fields null)         |
| 0x66 | `load.field`    | abc | `R[A] = R[B].field[C]`                                         |
| 0x67 | `store.field`   | abc | `R[A].field[B] = R[C]`                                         |

`invoke.dyn` resolves interpreted methods through the receiver's class table and
everything else through the host-API allow-list (`spec/host-api.md`), with a
per-call-site inline cache. Getters are zero-argument selectors.

### Closures and captured variables

| code | mnemonic      | fmt | effect                                                          |
| ---- | ------------- | --- | --------------------------------------------------------------- |
| 0x70 | `closure.new` | aBx | `R[A] =` closure over `F[Bx]`, capturing cells named by its `captures` |
| 0x71 | `upval.get`   | aBx | `R[A] =` current closure's upvalue cell `Bx`                     |
| 0x72 | `cell.new`    | a   | `R[A] = Cell(R[A])` — box the value for capture by reference     |
| 0x73 | `cell.get`    | ab  | `R[A] = (R[B] as Cell).value`                                    |
| 0x74 | `cell.set`    | ab  | `(R[A] as Cell).value = R[B]`                                    |

A captured local or parameter is boxed with `cell.new` at its definition; reads
and writes then go through `cell.get`/`cell.set`. `closure.new` reads the cell
references from the current frame's registers listed in `F[Bx].captures`, so the
same body can close over different environments. A returned closure keeps its
cells alive after the defining frame exits.

### Async

| code | mnemonic | fmt | effect                                                        |
| ---- | -------- | --- | ------------------------------------------------------------- |
| 0x80 | `await`  | a   | suspend the `async` function until `R[A]` (a Future) completes, then `R[A] =` its result |

`await` appears only in `isAsync` functions. If `R[A]` is not a `Future`, it is
left unchanged (Dart's `await` of a non-future). The runtime suspends by saving
the frame and returning control to the host event loop, and resumes at the next
instruction with the awaited value in `R[A]`.

### Type tests and exceptions

| code | mnemonic  | fmt | effect                                                        |
| ---- | --------- | --- | ------------------------------------------------------------- |
| 0x68 | `load.global`  | aBx | `R[A] =` module global `Bx` (a static field)               |
| 0x69 | `store.global` | aBx | module global `Bx` `= R[A]`                                 |
| 0x81 | `is.type`    | aBx | `R[A] = R[A] is T`, where `T` is the type spec `constants[Bx]` |
| 0x82 | `as.type`    | aBx | `R[A] = R[A] as T`; a failed cast raises a VM fault           |
| 0x83 | `throw`      | a   | raise `R[A]` as an exception                                  |
| 0x84 | `record.new` | aBx | build a record from `R[A]…` per shape `constants[Bx]`, into `R[A]` |
| 0x85 | `record.get` | aBx | `R[A] =` the field of record `R[A]` named by `constants[Bx]` |
| 0x86 | `yield`      | a   | in a generator, suspend and surface `R[A]` as the next element |

The type spec in `constants[Bx]` is a string: a core type (`int`, `String`,
`List`, …), a user-class or exception/error type name, or such a name with a
trailing `?` for nullability. `throw` searches the current function's
exception-handler table (§4.2) for a region covering the throw site; on a match
it places the raised value in the handler's catch register and jumps to its
target, otherwise it unwinds to the caller and repeats. A throw that no frame
handles escapes the interpreter as an uncaught-exception fault. Faults raised by
the VM itself (sandbox limits, a failed `as.type`, dispatch errors) are not
caught by these handlers.

`load.global` / `store.global` address module-level slots — one per static
field — that the static initializer (`Module.staticInit`) populates before the
entry point runs. `yield` suspends a `sync*`/`async*` generator: calling such a
function returns a lazy `Iterable`/`Stream` without running the body, and each
element pulled runs the body until the next `yield` (or completion). The body's
frame persists between pulls, so an infinite generator is fine when consumed
finitely; `ret`/`ret.void` ends the sequence.

`record.new` reads its shape from `constants[Bx]`, a string
`"<positionalCount>"` or `"<positionalCount>;<name1>,<name2>,…"`; the positional
fields occupy `R[A] … R[A+positionalCount-1]` and the named fields the registers
after them, in shape order. The resulting record replaces `R[A]`. `record.get`
reads a field of the record in `R[A]` — `"$1"`, `"$2"`, … for a positional field
or the field name for a named one — writing it back to `R[A]`. Records compare by
structural equality.

### Prefix

| code | mnemonic | fmt | effect                                        |
| ---- | -------- | --- | --------------------------------------------- |
| 0xF0 | `pfx`    | sAx | wide-mode extension of the next `aBx` (§3.1)  |

Codes not listed above are unassigned; a decoder MUST reject them. New opcodes
take unassigned codes and never repurpose an existing one.

---

## 6. Determinism

A conforming encoder MUST be deterministic: identical input and compiler version
yield byte-identical modules. In particular, constant-pool ordering MUST be a
pure function of the order constants are first added, and no wall-clock,
hash-seed, or map-iteration nondeterminism may leak into emitted bytes. This is
verified by golden fixtures in the compiler package.

---

## 7. Worked example

The Dart function

```dart
int add(int a, int b) => a + b;
```

compiles to a two-register frame (the parameters) plus one temporary:

```text
function F0 add(2 params, 3 regs)
  0000  add.i       R2, R0, R1
  0001  ret         R2
```

and the recursive

```dart
int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);
```

illustrates branches and calls (register numbers are illustrative):

```text
function F0 fib(1 params, 6 regs)
  0000  load.int    R1, 2
  0001  lt.i        R1, R0, R1
  0002  jz          R1, @0005        ; n < 2 false → recurse
  0003  ret         R0               ; base case: return n
  0005  load.func   R1, F0
  0006  load.int    R2, 1
  0007  sub.i       R2, R0, R2
  0008  call        R1, _, 1         ; fib(n-1) → R1
  0009  load.func   R2, F0
  0010  load.int    R3, 2
  0011  sub.i       R3, R0, R3
  0012  call        R2, _, 1         ; fib(n-2) → R2
  0013  add.i       R1, R1, R2
  0014  ret         R1
```
```

---

Part of **[Ejenix](https://github.com/ejenix/opensource)** — an open-source,
interpreter-based live-update stack for Flutter. See the
[project README](../README.md) for an overview, and
[`docs/production.md`](../docs/production.md) for running Ejenix in production.
