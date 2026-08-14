// Copyright (c) Ejenix authors. MIT license.

/// How the three operand bytes (A, B, C) of an instruction are interpreted.
///
/// Every instruction is a fixed 32-bit word: an 8-bit opcode followed by three
/// 8-bit operand bytes A, B, C (brief §6.1). The [OperandFormat] tells the
/// encoder, decoder, and disassembler how to read those three bytes for a
/// given [Op]. Operands wider than eight bits are supplied by a preceding
/// [Op.pfx] instruction (see [OperandFormat.aBx]).
enum OperandFormat {
  /// No operands. A, B, C are all zero.
  none,

  /// One register operand in A.
  a,

  /// Two register operands in A and B.
  ab,

  /// Three register operands in A, B, and C.
  abc,

  /// Register A plus a 16-bit unsigned operand `Bx = B | (C << 8)`.
  ///
  /// Used for pool/table indices. A preceding [Op.pfx] extends `Bx` with 24
  /// high bits, giving indices up to 40 bits wide without a second format.
  aBx,

  /// Register A plus a 16-bit signed operand `sBx` (a jump displacement in
  /// instruction words, relative to the following instruction).
  aSbx,

  /// A single 24-bit signed operand `sAx = A | (B << 8) | (C << 16)` (a jump
  /// displacement in instruction words, relative to the following instruction).
  sAx,
}

/// The complete instruction set.
///
/// Each opcode carries an explicit numeric [code]: the wire encoding is the
/// code, never the enum's declaration order, so the source may be reordered
/// without changing emitted bytes. Codes are permanent once shipped — new
/// opcodes take unused codes; existing codes never change meaning. This is the
/// determinism contract of the format (brief §10.4).
///
/// Register-based instruction set (brief §6.1): operands name registers in the
/// current frame's register file. Register machines dispatch fewer instructions
/// than stack machines under threaded interpretation — Ertl & Gregg, *"The
/// Structure and Performance of Efficient Interpreters"* (2003).
enum Op {
  // --- Constants and moves (0x00–0x0F) ---

  /// `load.const A, Bx` — `R[A] = constants[Bx]`.
  loadConst(0x00, OperandFormat.aBx, 'load.const'),

  /// `load.null A` — `R[A] = null`.
  loadNull(0x01, OperandFormat.a, 'load.null'),

  /// `load.true A` — `R[A] = true`.
  loadTrue(0x02, OperandFormat.a, 'load.true'),

  /// `load.false A` — `R[A] = false`.
  loadFalse(0x03, OperandFormat.a, 'load.false'),

  /// `load.int A, sBx` — `R[A] = sBx`, a small signed integer immediate in
  /// `[-32768, 32767]`. Larger literals go through the constant pool.
  loadInt(0x04, OperandFormat.aSbx, 'load.int'),

  /// `move A, B` — `R[A] = R[B]`.
  move(0x05, OperandFormat.ab, 'move'),

  /// `load.func A, Bx` — `R[A]` = a callable for `functions[Bx]` (a top-level
  /// or static function with no captured environment).
  loadFunc(0x06, OperandFormat.aBx, 'load.func'),

  /// `load.undef A` — `R[A]` = the "absent argument" sentinel. Emitted at a call
  /// site for an omitted optional or named parameter; the callee's prologue
  /// replaces any slot still holding the sentinel with that parameter's default.
  /// The sentinel is never reachable from Dart source, so `slot == sentinel`
  /// means exactly "the caller omitted this argument".
  loadUndef(0x07, OperandFormat.a, 'load.undef'),

  // --- Integer arithmetic (0x10–0x1F) ---

  /// `add.i A, B, C` — `R[A] = R[B] + R[C]` on `int` operands.
  addInt(0x10, OperandFormat.abc, 'add.i'),

  /// `sub.i A, B, C` — `R[A] = R[B] - R[C]` on `int` operands.
  subInt(0x11, OperandFormat.abc, 'sub.i'),

  /// `mul.i A, B, C` — `R[A] = R[B] * R[C]` on `int` operands.
  mulInt(0x12, OperandFormat.abc, 'mul.i'),

  /// `div.i A, B, C` — `R[A] = R[B] ~/ R[C]` (truncating integer division).
  /// Division by zero throws `IntegerDivisionByZeroException`.
  divInt(0x13, OperandFormat.abc, 'div.i'),

  /// `mod.i A, B, C` — `R[A] = R[B] % R[C]` on `int` operands (Dart `%`,
  /// result has the sign of the divisor).
  modInt(0x14, OperandFormat.abc, 'mod.i'),

  /// `neg.i A, B` — `R[A] = -R[B]` on an `int` operand.
  negInt(0x15, OperandFormat.ab, 'neg.i'),

  // --- Double arithmetic (0x20–0x2F) ---

  /// `add.d A, B, C` — `R[A] = R[B] + R[C]` on `double` operands.
  addDouble(0x20, OperandFormat.abc, 'add.d'),

  /// `sub.d A, B, C` — `R[A] = R[B] - R[C]` on `double` operands.
  subDouble(0x21, OperandFormat.abc, 'sub.d'),

  /// `mul.d A, B, C` — `R[A] = R[B] * R[C]` on `double` operands.
  mulDouble(0x22, OperandFormat.abc, 'mul.d'),

  /// `div.d A, B, C` — `R[A] = R[B] / R[C]` on `double` operands.
  divDouble(0x23, OperandFormat.abc, 'div.d'),

  /// `mod.d A, B, C` — `R[A] = R[B] % R[C]` on `double` operands.
  modDouble(0x24, OperandFormat.abc, 'mod.d'),

  /// `neg.d A, B` — `R[A] = -R[B]` on a `double` operand.
  negDouble(0x25, OperandFormat.ab, 'neg.d'),

  /// `i2d A, B` — `R[A] = (R[B] as int).toDouble()`. Widens an `int` to a
  /// `double` for mixed-type arithmetic and for the `/` operator, whose result
  /// is always `double`.
  i2d(0x26, OperandFormat.ab, 'i2d'),

  // --- Comparison (0x30–0x3F): result is a `bool` in R[A] ---

  /// `lt.i A, B, C` — `R[A] = R[B] < R[C]` on `int` operands.
  ltInt(0x30, OperandFormat.abc, 'lt.i'),

  /// `le.i A, B, C` — `R[A] = R[B] <= R[C]` on `int` operands.
  leInt(0x31, OperandFormat.abc, 'le.i'),

  /// `gt.i A, B, C` — `R[A] = R[B] > R[C]` on `int` operands.
  gtInt(0x32, OperandFormat.abc, 'gt.i'),

  /// `ge.i A, B, C` — `R[A] = R[B] >= R[C]` on `int` operands.
  geInt(0x33, OperandFormat.abc, 'ge.i'),

  /// `eq.i A, B, C` — `R[A] = R[B] == R[C]` on `int` operands.
  eqInt(0x34, OperandFormat.abc, 'eq.i'),

  /// `ne.i A, B, C` — `R[A] = R[B] != R[C]` on `int` operands.
  neInt(0x35, OperandFormat.abc, 'ne.i'),

  /// `lt.d A, B, C` — `R[A] = R[B] < R[C]` on `double` operands.
  ltDouble(0x36, OperandFormat.abc, 'lt.d'),

  /// `le.d A, B, C` — `R[A] = R[B] <= R[C]` on `double` operands.
  leDouble(0x37, OperandFormat.abc, 'le.d'),

  /// `gt.d A, B, C` — `R[A] = R[B] > R[C]` on `double` operands.
  gtDouble(0x38, OperandFormat.abc, 'gt.d'),

  /// `ge.d A, B, C` — `R[A] = R[B] >= R[C]` on `double` operands.
  geDouble(0x39, OperandFormat.abc, 'ge.d'),

  /// `eq A, B, C` — `R[A] = R[B] == R[C]` using Dart structural equality.
  eq(0x3A, OperandFormat.abc, 'eq'),

  /// `ne A, B, C` — `R[A] = R[B] != R[C]` using Dart structural equality.
  ne(0x3B, OperandFormat.abc, 'ne'),

  // --- Logical and control flow (0x40–0x4F) ---

  /// `not A, B` — `R[A] = !R[B]` on a `bool` operand.
  not(0x40, OperandFormat.ab, 'not'),

  /// `jmp sAx` — unconditional jump: `pc += sAx`.
  jmp(0x41, OperandFormat.sAx, 'jmp'),

  /// `jz A, sBx` — jump if zero/false: if `R[A]` is `false`, `pc += sBx`.
  jz(0x42, OperandFormat.aSbx, 'jz'),

  /// `jnz A, sBx` — jump if non-zero/true: if `R[A]` is `true`, `pc += sBx`.
  jnz(0x43, OperandFormat.aSbx, 'jnz'),

  // --- Calls and returns (0x50–0x5F) ---

  /// `call A, _, C` — call the callable in `R[A]` with `C` arguments in
  /// `R[A+1] .. R[A+C]`; on return the result is placed in `R[A]`.
  call(0x50, OperandFormat.abc, 'call'),

  /// `ret A` — return `R[A]` to the caller.
  ret(0x51, OperandFormat.a, 'ret'),

  /// `ret.void` — return `null` to the caller.
  retVoid(0x52, OperandFormat.none, 'ret.void'),

  // --- Dynamic dispatch and objects (0x60–0x6F) ---

  /// `invoke.dyn A, Bx` — dynamic method dispatch. `Bx` indexes the module's
  /// call-site table, which names the selector and argument count. The receiver
  /// is `R[A]` and arguments are `R[A+1] .. R[A+argCount]`; the result replaces
  /// `R[A]`. Getters are dispatched as zero-argument selectors. Inline caches
  /// key on the receiver's runtime shape (Deutsch-Schiffman, 1984).
  invokeDyn(0x60, OperandFormat.aBx, 'invoke.dyn'),

  /// `list.new A` — `R[A] = <Object?>[]`, a fresh growable list.
  listNew(0x61, OperandFormat.a, 'list.new'),

  /// `map.new A` — `R[A] = <Object?, Object?>{}`, a fresh linked map.
  mapNew(0x62, OperandFormat.a, 'map.new'),

  /// `set.new A` — `R[A] = <Object?>{}`, a fresh linked set.
  setNew(0x63, OperandFormat.a, 'set.new'),

  /// `invoke.static A, Bx` — call a host global (e.g. `print`). `Bx` indexes the
  /// call-site table; arguments are `R[A] .. R[A+argCount-1]` (no receiver) and
  /// the result replaces `R[A]`.
  invokeStatic(0x64, OperandFormat.aBx, 'invoke.static'),

  /// `alloc A, Bx` — `R[A]` = a fresh instance of `classes[Bx]`, its fields
  /// initialized to null. A constructor call then populates them.
  alloc(0x65, OperandFormat.aBx, 'alloc'),

  /// `load.field A, B, C` — `R[A] = R[B].field[C]`, reading instance field slot
  /// `C` of the object in `R[B]`.
  loadField(0x66, OperandFormat.abc, 'load.field'),

  /// `store.field A, B, C` — `R[A].field[B] = R[C]`, writing instance field slot
  /// `B` of the object in `R[A]`.
  storeField(0x67, OperandFormat.abc, 'store.field'),

  /// `load.global A, Bx` — `R[A] =` module global `Bx` (a static field). The
  /// static-initializer function populates the globals before the entry runs.
  loadGlobal(0x68, OperandFormat.aBx, 'load.global'),

  /// `store.global A, Bx` — module global `Bx` `= R[A]`.
  storeGlobal(0x69, OperandFormat.aBx, 'store.global'),

  // --- Closures and captured variables (0x70–0x7F) ---

  /// `closure.new A, Bx` — `R[A]` = a closure over `functions[Bx]`, capturing
  /// the cells named by that proto's `captures` list from the current frame's
  /// registers. A closure with an empty capture list is still distinct from a
  /// bare function reference in that it may be produced inside a scope.
  closureNew(0x70, OperandFormat.aBx, 'closure.new'),

  /// `upval.get A, Bx` — `R[A]` = the current closure's `upvalues[Bx]` (a cell).
  /// Reading or writing the captured variable then goes through `cell.get` /
  /// `cell.set`. Valid only inside a closure body.
  upvalGet(0x71, OperandFormat.aBx, 'upval.get'),

  /// `cell.new A` — `R[A] = Cell(R[A])`, boxing the value currently in `R[A]`
  /// so a nested closure can capture the variable by reference. Emitted for
  /// locals and parameters that are captured (Dart capture-by-reference).
  cellNew(0x72, OperandFormat.a, 'cell.new'),

  /// `cell.get A, B` — `R[A] = (R[B] as Cell).value`, reading a boxed variable.
  cellGet(0x73, OperandFormat.ab, 'cell.get'),

  /// `cell.set A, B` — `(R[A] as Cell).value = R[B]`, writing a boxed variable.
  cellSet(0x74, OperandFormat.ab, 'cell.set'),

  // --- Async (0x80) ---

  /// `await A` — suspend the enclosing `async` function until `R[A]` (a
  /// `Future`) completes, then place its result back in `R[A]`. Awaiting a
  /// non-`Future` yields the value unchanged. Emitted only inside functions the
  /// compiler marked `async`; the interpreter drives suspension via the host
  /// event loop (`spec/dart-subset.md`).
  awaitValue(0x80, OperandFormat.a, 'await'),

  /// `is.type A, Bx` — `R[A] = R[A] is T`, where `T` is the type named by the
  /// string `constants[Bx]` (a base type name, optionally suffixed `?`). Handles
  /// `dart:core` types and user classes (by walking the class table); a `is!`
  /// test is this followed by `not`.
  isType(0x81, OperandFormat.aBx, 'is.type'),

  /// `as.type A, Bx` — checked cast: if `R[A] is T` fails (per `is.type`) throws;
  /// otherwise `R[A]` is unchanged.
  asType(0x82, OperandFormat.aBx, 'as.type'),

  /// `throw A` — throw the value in `R[A]`. Propagates to the nearest enclosing
  /// exception handler (the function's handler table, then up the call stack);
  /// an uncaught throw surfaces as an [InterpreterUncaughtException].
  throwValue(0x83, OperandFormat.a, 'throw'),

  /// `record.new A, Bx` — build a record from the fields in `R[A] .. R[A+n-1]`
  /// and place it in `R[A]`. `constants[Bx]` is the shape string
  /// `"<positionalCount>"` or `"<positionalCount>;<name1>,<name2>,…"`; the first
  /// `positionalCount` registers are the positional fields, the rest the named
  /// fields in shape order.
  recordNew(0x84, OperandFormat.aBx, 'record.new'),

  /// `record.get A, Bx` — `R[A]` = the field of the record in `R[A]` named by
  /// `constants[Bx]`: `"$1"`, `"$2"`, … for positional fields, or the field name
  /// for named fields.
  recordGet(0x85, OperandFormat.aBx, 'record.get'),

  /// `yield A` — in a `sync*`/`async*` generator, suspend and surface `R[A]` as
  /// the next element; the generator resumes after it on the next pull.
  yieldValue(0x86, OperandFormat.a, 'yield'),

  // --- Prefix (0xF0) ---

  /// `pfx sAx` — wide-mode prefix. Supplies 24 additional high bits for the
  /// [OperandFormat.aBx] operand of the immediately following instruction,
  /// forming `Bx' = (payload << 16) | Bx`. Never appears on its own.
  pfx(0xF0, OperandFormat.sAx, 'pfx');

  const Op(this.code, this.format, this.mnemonic);

  /// The 8-bit wire encoding of this opcode. Stable and permanent.
  final int code;

  /// How this opcode's operand bytes are laid out.
  final OperandFormat format;

  /// Human-readable name used by the disassembler and specification.
  final String mnemonic;

  static final Map<int, Op> _byCode = {for (final op in values) op.code: op};

  /// Returns the opcode with the given wire [code].
  ///
  /// Throws [ArgumentError] if no opcode uses that code (an unknown or corrupt
  /// instruction). The map is built once and shared.
  static Op fromCode(int code) {
    final op = _byCode[code];
    if (op == null) {
      throw ArgumentError.value(code, 'code', 'unknown opcode');
    }
    return op;
  }
}
