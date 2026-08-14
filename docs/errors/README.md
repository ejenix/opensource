# Ejenix error catalog

Every fatal diagnostic the Ejenix toolchain emits carries a stable `E####` code,
`path:line:column`, a plain-language message, and — where useful — a correction.
This directory documents one file per code. The bar is the Elm and Rust
compilers (brief §6.2): no cryptic messages.

| Code    | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| [E0000](E0000.md) | Analyzer error (syntax or resolution) in the source       |
| [E0001](E0001.md) | Source could not be resolved into a compilation unit      |
| [E0100](E0100.md) | An expression or statement is outside the supported subset |
| [E0101](E0101.md) | A top-level declaration is outside the supported subset   |
| [E0102](E0102.md) | A function needs more than 255 registers                  |
| [E0200](E0200.md) | A sandbox-forbidden library was imported (permanent)      |

Codes are permanent once shipped; new diagnostics take new codes. The supported
Dart subset is defined in [`spec/dart-subset.md`](../../spec/dart-subset.md).

## Bundle verification failures

Verification failures reported by `ejenix verify` and the on-device loader are
enumerated by `BundleFailure` (`badMagic`, `incompatibleVersion`,
`bodyHashMismatch`, `badSignature`, `untrustedKey`). These are integrity
results, not compiler diagnostics; their semantics are specified in
[`spec/bundle.md`](../../spec/bundle.md).
