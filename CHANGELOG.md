# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — Unreleased

Set the release date here on the day the tag is published. This is the version
every package declares and the one `ejenix --version` reports; keep the three in
step when you bump.

### Added

- **Bytecode is verified before it is staged.** A signature proves origin, not
  structural safety — a leaked key, a compiler bug, or a hand-built artifact
  can produce a module that verifies cryptographically and indexes a register
  that does not exist. `verifyModule` checks opcodes, operand formats, register
  bounds, constant/function/class/call-site/global indices, jump targets,
  handler ranges, superclass acyclicity, and module quotas, reporting every
  defect rather than the first. Several of these invariants previously lived in
  Dart `assert`s, which release builds strip — they held while developing and
  vanished on the devices that matter.
- **Bundle decoding is total, bounded and exact.** Decoding runs before any
  signature check, so it is the first thing a hostile response reaches. It now
  rejects trailing bytes (which lie outside what a signature covers), rejects
  non-canonical integer encodings, bounds every declared length before it
  becomes an allocation, enforces the fixed widths of ids, digests, keys and
  signatures, and converts every failure to `BundleFormatException` so nothing
  escapes as a raw `RangeError` or `FormatException`.
- **Pointers are written atomically** on the device and the server. `state.json`
  and the environment record decide what runs; written in place, a crash between
  truncation and the final byte left them short. Both now write to a sibling,
  flush, and rename.
- **The scaffolded host no longer strands the screen.** A failed boot rendered a
  spinner forever — and `EjenixPatchView` was never constructed, so the
  `fallbackBuilder` could not run. It now falls back on error, bounds the boot
  with a deadline so a hang cannot strand it either, and resolves the boot
  future once instead of on every rebuild.
- **`--env` is required** on `ejenix promote` and `ejenix rollback`. It used to
  default to `production`, so omitting it released to real users without the
  word appearing in the command. Every documented invocation already passed it
  explicitly; only a bare `promote <id>` is affected, which is exactly the case
  worth refusing.
- **Channels** — the live bundle is keyed on `(appId, channel, env)`, so one app
  can have many patchable screens that promote and roll back independently. One
  app id, one signing key. `channel` defaults to `default` and the pre-channel
  routes still resolve to it, so existing installs need no migration.
- **Staged rollout** — `ejenix promote --rollout <percent>` exposes a patch to
  part of the fleet. Each device decides locally whether it is in the share by
  hashing its own install id against a published salt, so there is no device
  registry and nothing is reported back. Widening is monotonic: re-promoting the
  same bundle at a higher percentage only adds devices. Rollback always restores
  to 100%.
- Initial public release of the Ejenix interpreter-based live-update stack for
  Flutter.
- Control-plane tokens can be supplied by `--token-file`, `--token-stdin`, or
  `$EJENIX_TOKEN` / `$EJENIX_ADMIN_KEY`, all of which keep the token out of
  shell history and the process list. `--token` still works and is still
  honoured, but warns and now ranks last among explicit sources.
- `ejenix keygen` writes the private seed `0600` via a restricted temp file and
  an atomic rename, and refuses if the filesystem will not honour the mode. It
  previously used the ambient umask, which typically left the signing key
  world-readable.
- Bundle identity is immutable: re-uploading different bytes under an existing
  bundle id is refused (409), and the download ETag is a SHA-256 of the content
  rather than the id — an id-derived ETag let a re-upload split a fleet
  silently, with cached devices told 304 while fresh devices got new code.
- Deploy scripts redact secret values from every echoed command, including
  `--dry-run` output, which previously disclosed the admin key and delivery
  seed to terminal scrollback and CI logs.
- `--dry-run` is refused (not silently ignored) on the `docker` and
  `kubernetes` targets, which cannot honour it; `deploy.sh --target kubernetes`
  now creates the `ejenix-secrets` Secret the manifest requires.
- Register overflow is a build error (`E0102`) instead of a silent clamp to
  255, which previously produced a signed bundle whose registers aliased.
- Instruction budget for interpreted calls, on by default
  (`kDefaultPatchStepLimit`), so a patch that hangs falls back and rolls back
  instead of freezing the app. Configurable via `stepLimit` on
  `EjenixPatchView` / `InterpretedView`; overruns raise
  `StepLimitExceededException`, which interpreted `catch` cannot swallow. The
  budget is charged per host-entered invocation and spans `await` resumes,
  nested interpreted async calls, and generator turns.
- Built-in host capabilities that could allocate or consume without bound
  (`String *`, draining an iterable) carry explicit ceilings and raise
  `HostBudgetExceededException`. Capabilities an app registers itself are not
  metered — see `docs/production.md`.
- Control plane rejects app ids and environment names that are not plain slugs,
  closing a percent-encoded path traversal (`%2e%2e%2f`) that reached the file
  store through the route parameters.
- Register bytecode format and specification.
- Ed25519-signed bundle format with a canonical CBOR body.
- VCDIFF-style delta bundles between versions.
- Loader with signature verification, staging, and automatic crash-loop
  rollback.
- `ejenix` CLI: `keygen`, `build`, `verify`, `push`, `promote`, `rollback`,
  `inspect`, `doctor`, `watch`, `gen`, `init`, `scaffold`, `app`, `bench`.
- Self-hosted control plane with app, bundle, and environment endpoints, plus an
  operator dashboard.
- Flutter integration through `EjenixPatchView`, and capability codegen from
  `@Patchable` annotations.
- Example applications, and executable deploy targets for Docker, Kubernetes,
  Google Cloud Run, Azure Container Apps, AWS App Runner, and systemd — each
  with a `--dry-run` that prints its plan without touching your account.
