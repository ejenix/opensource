# Benchmarks

Coarse, reproducible micro-benchmarks of interpreter dispatch throughput. Every
number is falsifiable: it names the machine, OS, and Dart version, and the exact
command that produced it. These are relative signals for the dispatch design,
not marketing figures — run them yourself.

## Reproduce

```sh
dart run ejenix_cli:ejenix bench --iterations 10
# machine-readable:
dart run ejenix_cli:ejenix --json bench --iterations 10
```

Each benchmark runs an AOT-friendly module through the register VM and reports
the best `ns/op` across the iterations, where an "op" is one executed bytecode
instruction (counted by the interpreter's opcode profiler). Lower `ns/op` and
higher `ops/sec` are better.

## What each benchmark measures

| Benchmark       | Exercises                                                        |
| --------------- | --------------------------------------------------------------- |
| `fib(30)`       | **Threaded dispatch**, call/return heavy (recursive Fibonacci)  |
| `sum-loop(1e6)` | **Threaded dispatch**, arithmetic + branch in a tight loop      |
| `dispatch(1e6)` | **Inline-cache dispatch**: a hot, monomorphic `invoke.dyn`      |

`dispatch(1e6)` issues the same `invoke.dyn 'length'` on a `String` every
iteration, so the call site's inline cache is monomorphic after the first hit —
isolating inline-cache dispatch cost (Deutsch-Schiffman, 1984).

## Reference results

Reference environment:

- **CPU:** Apple M5
- **OS:** macOS (`Darwin arm64`)
- **Dart:** 3.11.4 (stable), AOT via `dart run`
- **Command:** `ejenix bench --iterations 10`

| Benchmark       | ns/op | ops/sec |
| --------------- | ----- | ------- |
| `fib(30)`       | ~23.5 | ~42.5M  |
| `sum-loop(1e6)` | ~19.0 | ~52.6M  |
| `dispatch(1e6)` | ~23.4 | ~42.7M  |

Notes:

- Threaded dispatch uses a dense `switch` that the Dart AOT compiler lowers to an
  indirect-branch jump table — Dart exposes no computed-`goto`, so this is the
  brief's documented "jump-table fallback" (`spec/bytecode.md` §6.3), not a
  claim of hand-written threaded code.
- Small integers ride the Dart VM's native tagged (Smi) representation, so
  arithmetic avoids a manual boxing layer.
- Inline-cache dispatch lands within ~20% of raw threaded dispatch here because
  the monomorphic fast path is a single type compare before the cached method
  call; a megamorphic site would be slower and is the case the cache exists to
  bound.

Numbers vary with CPU, thermal state, and Dart version. Re-run on your target
hardware; the `--json` output is stable for scripting a regression check.

---

## The `ejenix watch` dev loop

The brief (§13) budgets the edit→push round trip at **under 500 ms**. Reproduce:

```sh
dart run packages/cli/tool/watch_bench.dart
```

It benchmarks the real example patch — 10 functions, importing the full Flutter
patch SDK — because the cost that matters is re-resolving a realistic import
graph, not a toy file.

Reference environment: Apple M5, macOS (`Darwin arm64`), Dart 3.12.2.

| Phase                          |    p50 |    p95 |
| ------------------------------ | -----: | -----: |
| Compile (resolve + lower)      | 4.4 ms | 21.0 ms |
| Sign (Ed25519 + CBOR encode)   | 0.8 ms |  1.5 ms |
| **Total rebuild**              | **5.4 ms** | **22.0 ms** |

**Worst observed: 22 ms — a 23× margin under the 500 ms budget.**

Cold start, paid **once** when `ejenix watch` boots: ~780 ms.

### Why it is fast

Nothing clever — one decision. `Compiler.compileFile` builds a fresh
`AnalysisContextCollection` per call and discards it, so every compile re-reads
and re-resolves the SDK and every dependency. That is right for a one-shot build
and fatal for a loop: it costs ~800 ms *per keystroke-ish save*.

`IncrementalCompiler` holds one analysis context open and tells the analyzer only
which file changed, so a rebuild re-resolves the edited library and reuses
everything else. That is the entire difference between ~800 ms and ~5 ms.

The end-to-end round trip an app actually experiences — save → watcher → compile
→ sign → SSE notification → refetched bytes — is asserted against the 500 ms
budget in `packages/cli/test/watch_test.dart`, so a regression fails CI rather
than merely feeling slow. The assertion is on the **worst** sample, not the
median: a p50 that hides a 2-second p100 is exactly the loop that feels broken in
practice.
