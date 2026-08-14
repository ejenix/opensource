# Contributing to Ejenix

Thanks for helping build Ejenix — a world-class, verifiable over-the-air patch
stack for Flutter. Ejenix holds a hard quality bar because it signs code that
runs on production devices.

## The gate (must be green before merge)

Every change must pass, on the whole workspace:

```sh
dart pub get
dart format --output=none --set-exit-if-changed packages   # formatting is not optional
dart analyze packages                                       # ZERO warnings, not just errors
dart test packages                                          # all tests pass
tool/coverage.sh packages/<pkg>                             # ≥ 90% line coverage, every package
```

CI runs all of the above (see `.github/workflows/ci.yml`) on Linux, macOS, and
Windows, and enforces the 90% floor per package. A PR that drops any package
below 90% will not merge.

## Principles

- **Determinism is a feature.** The same source and compiler version must
  produce byte-identical bundles. No map iteration order, wall-clock, or hash
  randomization may influence emitted bytes. Golden tests pin exact output.
- **Never mis-compile.** Anything outside the supported Dart subset
  (`spec/dart-subset.md`) must be rejected with a located, actionable
  diagnostic — never silently accepted or wrongly lowered.
- **Opcodes are append-only.** An opcode's numeric `code` is permanent once
  shipped; new opcodes take unused codes. Bundle body versions bump on any
  breaking layout change.
- **Spec first.** A change to the bytecode, bundle, delta, subset, or host API
  updates the corresponding file in `spec/` in the same PR.
- **Sandbox boundary.** The interpreter reaches the host only through the
  `HostRegistry` allow-list. Do not add ambient host access.

## Adding a language feature

1. Extend `spec/dart-subset.md` (move it from *planned* to *supported*).
2. Add opcodes to `packages/bytecode` if needed (append-only), with disassembler
   support and the opcode reference in `spec/bytecode.md`.
3. Implement lowering in `packages/compiler` and execution in
   `packages/interpreter`.
4. Add tests covering runtime behavior, a diagnostic for the still-unsupported
   edge, and a bundle round-trip if the module layout changed.

## Commit and PR style

Keep changes focused. Match the surrounding code's style, comment density, and
naming. Every source file carries the MIT header. Reference issues in the PR
body; describe the observable behavior change and how you verified it.
