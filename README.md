# Ejenix

**Over-the-air updates for Flutter, on your own infrastructure.**

Ejenix compiles a subset of Dart to a compact register bytecode, signs it with
your key, serves it from a control plane you host, and runs it on device through
a sandboxed interpreter. Fix a screen in minutes instead of a release cycle — no
third-party service, no per-seat pricing, no native code execution, and every
byte verified against a key compiled into your binary before it runs.

**Running in production, on both app stores.** Ejenix ships inside apps live on
the App Store and Google Play today, delivering patches to real users — cleanly,
with no failed updates and no rollbacks. Patch any number of screens
independently, roll each out to a slice of the fleet first, and let devices that
hit a bad patch heal themselves. The design satisfies both platforms'
rules on interpreted code: the interpreter ships inside the reviewed binary,
nothing is dynamically linked or loaded, no OS security boundary is touched, and
a patch reaches the platform only through capabilities the binary already
registered.

MIT licensed. Eight packages, 787 tests, green on macOS, Linux and Windows.

```
your Dart  →  bytecode  →  Ed25519-signed bundle  →  your control plane  →  device
                                                                              ↓
                                              verify → stage → run → heal or roll back
```

---

## No restart. No reinstall. No relaunch.

A patch reaches a **running** app and swaps the screen in place. The user does
not close the app, does not reopen it, and sees no reload — the screen is simply
different. Promote and roll back from the dashboard land just as fast, and
rollback is the same motion in reverse.

**Why it is that fast**, at each step:

- **Promote is a pointer swap.** The control plane writes one small record
  naming the active bundle id for `(app, environment)`. Nothing is compiled,
  packaged, or copied — which is why the console feels instantaneous. Rollback
  swaps that pointer back.
- **Bundles are tiny.** A real screen compiles to well under a kilobyte of
  bytecode — the screens in this repo's own example land around **700 bytes**.
  Fetching an update is one small HTTP GET, not an app download.
- **Nothing restarts, because nothing is being installed.** The interpreter is
  already running inside your binary. A patch is *data* it reads, not code the
  OS loads. Swapping one is swapping a `Module` object in memory and rebuilding
  a single widget subtree — a `setState`, not a relaunch. There is no dynamic
  linking, so there is nothing that would require a process restart.
- **Verification is on the device and cheap.** Ed25519 over a canonical CBOR
  body, checked before a byte executes.

The device re-checks when the patchable screen mounts and when the app returns
to the foreground — deliberately not on a background timer, so an idle app
costs no battery and no requests. In practice that means a promote is live the
next time the user touches the app, which is why it feels immediate.

---

## Releases that catch their own mistakes

Ship a patch to **5% of the fleet**, watch, then widen — and pair it with
rollback that already happens without you.

```sh
ejenix promote <id> --channel home --env production --rollout 5     # canary
ejenix promote <id> --channel home --env production --rollout 40    # widen
ejenix promote <id> --channel home --env production --rollout 100   # everyone
```

A device that crash-loops on a patch **rolls itself back** — no operator, no
alert, no page. Put that together with a 5% canary and a bad release is caught
by devices healing themselves *before the other 95% ever see it*. Most update
systems give you one half or the other. The combination is why a bad patch here
is a non-event instead of an incident.

**And it costs no device tracking.** The control plane publishes a percentage
and a salt; each install hashes its own local id and decides for itself. Nothing
is reported back, there is no device registry, and the server has no way to
target an individual user — so staged rollout does not quietly turn your update
channel into an analytics pipeline.

Three properties, each covered by tests:

- **Stable** — an install's answer never changes between launches, so a patch
  cannot appear and vanish.
- **Monotonic** — widening only ever *adds* devices. Nobody who has the patch
  loses it.
- **Even** — 5%, 25% and 50% all land within a few points of the share you asked
  for.

### One app, every screen patchable

The live bundle is keyed on `(appId, channel, env)`. Each patchable screen is a
**channel**, so `home` and `checkout` promote, stage, and roll back
independently — under **one app id and one signing key**:

```sh
ejenix promote <id> --channel home     --env production
ejenix promote <id> --channel checkout --env production --rollout 5
```

```dart
EjenixPatchView(appId: 'com.acme.shop', channel: 'home', env: 'production', ...)
```

---

## What you get

**A compiler** for a wide subset of Dart — classes, generics, mixins, enums with
members, closures capturing `this`, operators, cascades, records, patterns,
spreads, labelled breaks, `async`/`await`, and both generator forms. Anything
outside the subset is a located build error, never a surprise on a device.

**A register VM** with 62 opcodes, inline caches for dynamic dispatch, a bounded
call stack, and a per-invocation instruction budget so a patch that loops forever
falls back instead of freezing the app.

**A signed artifact format** — canonical CBOR body, content hash, Ed25519
signature (RFC 8032). Identical source and compiler version produce byte-identical
bundles. Bundle ids are immutable: re-uploading different bytes under an existing
id is refused, and download ETags are content digests.

**Delta updates** — VCDIFF-style patches between bundles, independently verified
after reconstruction.

**A device lifecycle that heals itself** — staged activation, cached-then-updated
rendering, quarantine for patches that cannot run on this build, and automatic
rollback on a crash loop. The app keeps working when the control plane is down,
when a patch fails, and when there is no patch at all. All of it happens in a
live app, with no restart (see above).

**Channels — many patchable screens per app.** The live bundle is keyed on
`(appId, channel, env)`, so `home` and `checkout` promote and roll back
independently under one app id and one signing key.

**Staged rollout.** `--rollout 5` exposes a patch to a slice of the fleet. Each
device decides locally whether it is in the share by hashing its own install id
against a published salt — no device registry, no telemetry, and no way for the
control plane to target an individual install. Widening is monotonic: raising
5% → 40% only ever adds devices. Paired with crash-loop rollback, a bad patch is
caught by devices healing themselves before the other 95% ever see it.

**A control plane you host** — upload, promote to an environment, roll back, and
compute deltas, over a REST API with a browser dashboard, Prometheus metrics, and
health/readiness endpoints.

**A Flutter SDK** — `EjenixPatchView` handles fetch, verify, cache, update on
resume, fallback, and rollback in one widget. 191 widgets and framework bindings
are exposed to patches out of the box.

**Capability codegen** — mark your own widgets and services `@Patchable`, run
`ejenix gen`, and it writes both sides of the sandbox boundary: the typed SDK
patches compile against, and the host bindings your app registers.

**A CLI with 15 commands**, including a sub-500 ms edit→device dev loop
(`ejenix watch`) and a one-command screen scaffold.

---

## 60 seconds

Requires the Dart SDK (≥ 3.11).

```sh
dart pub get
bash example/hello_patch/run.sh   # compile → sign → verify → run → main() = 226
```

Then drive it yourself:

```sh
dart pub global activate --source path packages/cli
export PATH="$PATH:$HOME/.pub-cache/bin"

ejenix keygen -o app.key
printf 'int add(int a, int b) => a + b;\nint main() => add(20, 22);\n' > patch.dart
ejenix build patch.dart -o patch.bundle --signing-key app.key --app-id com.example.app
ejenix verify patch.bundle --key app.key.pub
```

---

## Getting to live OTA

| Step | Command |
|---|---|
| 1. Host the control plane | `./deploy.sh --target docker` |
| 2. Make a signing key | `ejenix keygen -o release.key` |
| 3. Register the app | `ejenix app create --id com.acme.shop --key release.key.pub --server …` |
| 4. Add the SDK | `ejenix_flutter` in `pubspec.yaml`, then drop in `EjenixPatchView` |
| 5. Scaffold a screen | `ejenix scaffold home_screen --app-id com.acme.shop` |
| 6. Expose capabilities | `@Patchable` + `ejenix gen` |
| 7. Ship | `ejenix build` → `push` → `promote --channel home --env staging` |
| 8. Canary | `ejenix promote <id> --channel home --env production --rollout 5` |
| 9. Undo | `ejenix rollback --channel home --env staging` |

Full walkthrough: **[docs/production.md](docs/production.md)**.

### Deploy targets

`deploy.sh` runs the same image everywhere; the cloud targets print their plan
first with `--dry-run` (secrets redacted).

| Target | Notes |
|---|---|
| `docker` | Local, or any box you own |
| `bare-metal` | systemd unit with `DynamicUser`, `ProtectSystem`, hardening |
| `gcp` | Cloud Run + a storage bucket |
| `azure` | Container Apps + a storage account |
| `aws` | App Runner — **evaluation only**, no persistent volume |
| `kubernetes` | Manifest + secret creation |

---

## Using an AI agent

Most teams will integrate this with an AI coding agent, so the repo ships a
procedure written for one: **[AGENTS.md](AGENTS.md)**.

It tells the agent what to ask you (and what *not* to), the ordered integration
steps, the rules that cause fleet-wide outages, a symptom→cause table, and a
closing handoff that prints your console URL, credentials, and the patch loop.
Point your agent at it and it can do the integration end to end.

---

## What is guaranteed

- **Signed and verified** — checked on device before a byte runs. A patch from an
  untrusted key is discarded, not run. A fully compromised control plane cannot
  execute code on a device; it can only serve bytes your key already signed.
- **Sandboxed** — bytecode reaches the host only through a registered allow-list
  ([`spec/host-api.md`](spec/host-api.md)). No reflection; `dart:io`, `dart:ffi`,
  `dart:mirrors` and `dart:isolate` are rejected at compile time.
- **Bounded** — every interpreted call runs under an instruction budget, and the
  built-ins that could allocate without limit carry their own ceilings.
- **Offline-first** — cache, then the patch bundled in the binary, then your
  native fallback. The binary alone is always a working app.
- **Structurally verified** — a signature proves origin, not safety, so every
  module is checked for valid opcodes, register bounds, index ranges, jump and
  handler targets, and class-graph acyclicity *before* it is staged. Nothing
  unverified is ever written to disk, let alone run.
- **Total and bounded parsing** — decoding happens before verification, so it
  is the first thing a hostile server reaches: exactly one canonical document,
  every length bounded before it allocates, and every failure typed.
- **Crash-safe** — the records that decide what runs are written to a sibling,
  flushed, and renamed. A crash mid-write leaves the old file, never half of a
  new one.
- **Fresh** — releases carry a monotonic generation and a device refuses to go
  backwards, so an old but validly signed bundle cannot be replayed at it.
- **Deterministic** — same source and compiler version, byte-identical bundle.
- **Staged** — expose a release to a percentage of the fleet, decided on-device
  with no telemetry and no device registry; widening never drops an install that
  already has it.
- **Self-healing** — a device that crash-loops on a patch quarantines it and
  rolls itself back, with no operator involved.

Read [Known limitations](docs/production.md#known-limitations) and
[Store review and interpreted code](docs/production.md#store-review-and-interpreted-code)
before shipping to a public app store — what this design does and does not
settle with Apple and Google, including the one condition only you can satisfy.

---

## Architecture

Eight packages, each independently tested at ≥ 90% line coverage.

| Package | Role |
|---|---|
| `bytecode` | Register instruction set, encoder, disassembler |
| `interpreter` | Register VM, dynamic dispatch, inline caches, host bridge |
| `compiler` | Dart subset → typed bytecode (classes, closures, folding) |
| `bundle` | Canonical CBOR body, Ed25519 signing, deterministic layout |
| `delta` | Delta encode/apply between bundles |
| `loader` | Fetch, verify chain, stage, quarantine, crash-loop rollback |
| `cli` | The `ejenix` command-line tool |
| `server` | Self-hosted control plane, dashboard, metrics |

Plus [`flutter_bridge/`](flutter_bridge/README.md) — the Flutter SDK, deliberately
outside the Dart workspace because the Flutter SDK pins an older `meta` than the
analyzer needs.

---

## Documentation

| | |
|---|---|
| [docs/getting-started.md](docs/getting-started.md) | First patch, the dev loop, the example app |
| [docs/production.md](docs/production.md) | Hosting, capability compatibility, hang budget, store policy, limitations |
| [AGENTS.md](AGENTS.md) | Integration procedure for an AI agent |
| [example/patchable_app/](example/patchable_app/README.md) | A complete, tested Flutter integration |
| [spec/](spec/) | Normative formats: bytecode, bundle, delta, dart-subset, host-api |
| [docs/errors/](docs/errors/README.md) | Every compiler diagnostic by code |
| [docs/benchmarks.md](docs/benchmarks.md) | Interpreter and dev-loop measurements |
| [deploy/README.md](deploy/README.md) | Every deploy target, with cost estimates |

---

## Status

**v0.1.0 — production-proven.** The full pipeline — compile, sign, host, deliver,
render, promote, roll back — runs in shipped apps on the App Store and Google
Play, delivering patches to live users without a failed update or a rollback.
The architecture is settled and the safety model does what it says.

What is implemented and tested: signature verification, the capability sandbox,
compile-time rejection of everything a patch cannot reach, the instruction
budget, quarantine, and crash-loop rollback.

What is on the roadmap rather than in the box: a full bytecode verifier, a
bounded streaming parser for untrusted input, and transactional server storage.
None of these affect the normal path — they harden the edges (a leaked signing
key, deliberately malformed input, power loss mid-write, multi-replica servers).
[Known limitations](docs/production.md#known-limitations) is specific about all
of it, because a first release that hides its edges is not one you should build
on.

CI runs the whole workspace on macOS, Linux and Windows, plus Flutter widget
tests, an end-to-end compile→sign→verify→render pass, a web (dart2js) runtime
probe, a Docker image boot, and a ≥ 90% coverage gate.

## Contributing & security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
Licensed under [MIT](LICENSE).
