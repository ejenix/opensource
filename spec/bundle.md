# Ejenix Bundle Specification

**Status:** Draft · **Format version:** 1.0 (body v8) · **Last updated:** 2026-07-13

This document defines the Ejenix signed bundle: the verifiable unit of delivery.
A bundle serializes a compiled module (or, for deltas, a patch) as canonical CBOR,
wrapped with a content hash and an Ed25519 signature (RFC 8032). The reference
implementation is `packages/bundle/`. RFC 2119 keywords apply.

---

## 1. Encoding

All structures use canonical CBOR (RFC 8949 §4.2.1): definite-length items,
shortest-form integer arguments, 64-bit floats. The schema is **entirely
positional** — CBOR arrays, never maps — so there is no map-key ordering rule to
canonicalize, and identical inputs always encode to identical bytes. This is the
determinism contract: the same module, id, timestamp, and compiler version
always produce the same bundle bytes and therefore the same signature.

Only these value kinds ever appear: unsigned/negative integers, byte strings,
text strings (UTF-8), arrays, `true`/`false`, `null`, and 64-bit floats.

---

## 2. Structure

A bundle is a 4-element CBOR array:

```text
[ header-bytes, public-key, signature, body-bytes ]
```

| Field                | CBOR   | Notes                                        |
| -------------------- | ------ | -------------------------------------------- |
| `header-bytes`       | bytes  | the signed header (§2.1), stored verbatim    |
| `public-key`         | bytes  | 32-byte Ed25519 public key                   |
| `signature`          | bytes  | 64-byte Ed25519 signature over `header-bytes`|
| `body-bytes`         | bytes  | the CBOR body (§3), stored verbatim          |

`header-bytes` and `body-bytes` are held as opaque byte strings so verification
re-hashes and re-parses the exact original encoding — never a re-encoding.

### 2.1 Header

`header-bytes` decodes to a 7-element CBOR array:

```text
[ magic, version-major, version-minor, bundle-id, created-at, compiler-version, body-sha256 ]
```

| Field              | CBOR  | Notes                                    |
| ------------------ | ----- | ---------------------------------------- |
| `magic`            | bytes | `"INTP"` (`0x49 0x4E 0x54 0x50`)         |
| `version-major`    | int   | `1`                                      |
| `version-minor`    | int   | `0`                                      |
| `bundle-id`        | bytes | 16-byte UUIDv7 (RFC 9562)                |
| `created-at`       | int   | Unix milliseconds                        |
| `compiler-version` | text  | semantic version of the producing tool   |
| `body-sha256`      | bytes | 32-byte SHA-256 of `body-bytes`          |

The Ed25519 signature is computed over the exact `header-bytes`. Because the
header commits to `body-sha256`, a valid signature authenticates the entire
body transitively.

---

## 3. Body

`body-bytes` decodes to a 9-element CBOR array:

```text
[ body-format-version, constants, functions, entry-function,
  global-count, static-init, call-sites, classes, metadata ]
```

- **`body-format-version`** (int): the current version is `8`. It is bumped only
  on a breaking layout change: v2 added the call-site table, v3 the class table,
  v4 each function's capture list, v5 the async flag, v6 each function's
  exception-handler table, v7 the static-field global count and initializer
  index, v8 widened the async flag to a function-kind int. A decoder rejects a
  body whose version it does not implement.
- **`constants`** (array): the constant pool, each entry a native CBOR value
  (`int` → integer, `double` → float64, `String` → text, `bool`, `null`). The
  native type distinction is how `1` and `1.0` remain distinct on decode.
- **`functions`** (array): each a 7-element array
  `[ name, param-count, register-count, code-bytes, captures, kind,
  handlers ]`. `code-bytes` is the instruction stream, 4 bytes per 32-bit word,
  little-endian, independent of host byte order. `captures` is an array of the
  defining frame's register indices a closure captures (empty for non-closures).
  `kind` is the function kind: `0` sync, `1` `async`, `2` `sync*`, `3` `async*`.
  `handlers` is the
  exception-handler table: an array of `[ start, end, target, catch-reg ]`
  entries, each a half-open `[start, end)` range of code-word offsets whose
  throws jump to `target` with the exception placed in register `catch-reg`.
  Handlers are tried in order, so inner regions take precedence; empty for
  functions with no `try`.
- **`entry-function`** (int): index into `functions`, or `-1`.
- **`global-count`** (int): the number of module-level global slots (static
  fields), addressed by `load.global` / `store.global`.
- **`static-init`** (int): the index of the static-initializer function run once
  before the entry point, or `-1` when there are no static fields.
- **`call-sites`** (array): the dynamic-dispatch table, each entry a 2-element
  array `[ selector, arg-count ]`, indexed by `invoke.dyn` / `invoke.static`.
- **`classes`** (array): the class table, each entry
  `[ name, field-count, super-index, methods, fields ]`, where `methods` and
  `fields` are arrays of `[ name, index ]` pairs. Ordered so a superclass
  precedes its subclasses. Indexed by `alloc`.
- **`metadata`** (array): `[ target-app-id, target-flutter-version, min-sdk ]`,
  all text.

The body is a positional array with no maps, so encoding is deterministic
without a key-ordering rule: identical inputs produce identical bytes, which is
what makes the content hash and signature reproducible.

---

## 4. Verification

A verifier MUST check, in this order, and stop at the first failure (brief §6.6):

1. **Magic + version.** `magic == "INTP"` and `version-major == 1`.
2. **Body hash.** `SHA-256(body-bytes) == body-sha256` from the header.
3. **Signature.** Ed25519 verify `signature` over `header-bytes` with
   `public-key`.
4. **Trust anchor.** `public-key` is in the verifier's trusted set.

Metadata compatibility (target app id, Flutter version, min SDK) is checked by
the loader against the host, not by the bundle verifier — see
`spec/host-api.md` and `packages/loader/`.

Each failure has a distinct typed reason so callers can log and act precisely.

---

## 5. Cryptography

- **Hash:** SHA-256.
- **Signature:** Ed25519 (RFC 8032). The signing key is stored and transported
  as its 32-byte seed and stays local to the developer's machine.
- **Constant-time comparison** is used for hash and root equality checks.

---

## 6. Compatibility

The format is a contract. After v1.0.0 the layout does not change in a breaking
way; a breaking change takes a new `magic`/`version-major` and a parallel
loader path (brief §10.5). New optional data is appended, and readers that do
not understand a trailing addition ignore it.

---

Part of **[Ejenix](https://github.com/ejenix/opensource)** — an open-source,
interpreter-based live-update stack for Flutter. See the
[project README](../README.md) for an overview, and
[`docs/production.md`](../docs/production.md) for running Ejenix in production.
