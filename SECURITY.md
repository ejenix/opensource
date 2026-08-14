# Ejenix Security Policy

Ejenix ships signed code to production devices. We take the security posture of
Ejenix seriously and welcome coordinated disclosure.

## Reporting a vulnerability

**Do not open a public issue for a security report.**

- Preferred: use GitHub's **private vulnerability reporting** on this repository
  (Security → *Report a vulnerability*). This opens a private advisory only the
  maintainers can see.
- Alternative: email **security@ejenix.com** with the details below. For a
  sensitive report, prefer the private advisory above.

Please include:

- The affected component (`bytecode`, `interpreter`, `compiler`, `bundle`,
  `delta`, `loader`, `cli`, or `server`) and version/commit.
- A minimal reproduction and the impact you observed.
- Any proof-of-concept bundle, key material, or network capture — as
  attachments, never pasted into a public channel.

We aim to acknowledge within **3 business days** and to ship a fix or mitigation
for a confirmed high-severity issue within **30 days**, crediting you in the
release notes unless you prefer to remain anonymous.

## Scope and threat model

The security boundary is the **loader/verifier** and the interpreter sandbox.
Reports are especially valuable when they show:

- A bundle that **verifies** against a trusted key but was not produced by that
  key (signature forgery), or a tampered body that passes the content hash.
- Interpreted bytecode **escaping the sandbox** — reaching host state outside
  the registered host-API allow-list (`spec/host-api.md`), reflection,
  `dart:io`/`dart:ffi`/`dart:isolate`, or unbounded resource use that defeats
  the step/stack limits.
- A crafted bundle that **bypasses crash-loop rollback** or the
  `minSdk`/`targetAppId` compatibility gates.
- Determinism breaks that let two different sources produce the **same** signed
  bytes, or the same source produce **different** bytes.

Out of scope: attacks that require an already-compromised signing key or a
device the attacker fully controls; these are trust-model assumptions, not
vulnerabilities (see `spec/bundle.md`).

## Supported versions

Until `v1.0.0`, only the latest `main` is supported. After `v1.0.0`, the latest
minor release receives security fixes.
