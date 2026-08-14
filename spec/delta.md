# Ejenix Delta Specification

**Status:** Draft · **Format version:** 1.0 · **Last updated:** 2026-07-12

This document defines Ejenix delta bundles: a compact patch against a cached base
bundle, so an update ships a fraction of a full bundle's bytes. The reference
implementation is `packages/delta/`. RFC 2119 keywords apply.

---

## 1. Overview

A delta bundle reuses the full bundle envelope (`spec/bundle.md` §2) unchanged —
same header, same Ed25519 signature — with a **delta body** in place of a module
body. The loader verifies the signature exactly as for a full bundle, then
applies the patch against the locally cached base body and checks the declared
post-patch hash before staging (brief §6.5, §6.6). A tampered patch cannot
produce a body that both applies and matches the hash the signed body committed
to.

---

## 2. Patch format

The patch is a stream of `COPY`/`ADD` operations — the VCDIFF (RFC 3284) and
bsdiff (Percival, 2003) lineage — describing how to build the target from the
base:

```text
patch      = zlib( target-length , op* )
target-length = varint                 ; total output length
op         = COPY | ADD
COPY       = 0x00 , varint offset , varint length   ; copy from base[offset..]
ADD        = 0x01 , varint length , length bytes    ; literal insert
```

- `varint` is unsigned LEB128.
- The op stream is zlib-compressed (RFC 1950) as a whole; pure-Dart codec, so it
  runs on every target platform including Wasm.
- The producer finds matches with a hash index over the base's 4-byte windows
  and greedy longest-extension. Any conforming producer MAY use a different
  matcher; the patch format and the applier are what is normative.

### 2.1 Applying

A conforming applier MUST:

1. zlib-inflate the patch; reject non-inflatable input.
2. Read `target-length` and allocate the output.
3. Replay ops in order. A `COPY` whose `offset+length` exceeds the base, or any
   op that would overrun `target-length`, MUST be rejected.
4. Reject a result whose length is not exactly `target-length`.

Applying is total: every input either yields the exact target or a typed error.

---

## 3. Delta body

The delta body is a 3-element CBOR array:

```text
[ base-bundle-id , patch , post-patch-sha256 ]
```

| Field               | CBOR  | Notes                                          |
| ------------------- | ----- | ---------------------------------------------- |
| `base-bundle-id`    | bytes | 16-byte id of the base this patches            |
| `patch`             | bytes | the compressed patch (§2)                      |
| `post-patch-sha256` | bytes | 32-byte SHA-256 the reconstructed body must match |

This body is what the bundle envelope signs and hashes, so the patch and the
expected result are both covered by the signature.

---

## 4. Loader flow

1. The control plane serves a delta from base *X* to target *Y* (or the loader
   requests one).
2. The loader verifies the delta bundle's signature and trust anchor
   (`spec/bundle.md` §4).
3. The loader locates its cached base body for `base-bundle-id`. If absent, it
   falls back to fetching the full target bundle.
4. It applies the patch and checks `SHA-256(result) == post-patch-sha256`. On
   mismatch it discards the result and MAY retry with a full bundle.
5. The reconstructed bytes are a normal bundle body and are staged as usual.

---

## 5. Size target

For typical iterative changes the delta is well under **10%** of the full bundle
(brief §6.5), because a small source edit changes only a localized region of the
compiled body and the rest is expressed as `COPY`s. The figure is instrumented
in `docs/benchmarks.md`; the ratio test in `packages/delta/test/` asserts the
bound on a representative case.

---

Part of **[Ejenix](https://github.com/ejenix/opensource)** — an open-source,
interpreter-based live-update stack for Flutter. See the
[project README](../README.md) for an overview, and
[`docs/production.md`](../docs/production.md) for running Ejenix in production.
