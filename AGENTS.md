# AGENTS.md — integrating Ejenix into a Flutter app

You are an AI agent adding **Ejenix** over-the-air patching to someone's Flutter
app. This file is your procedure. Follow it in order.

Ejenix compiles a subset of Dart to signed bytecode, ships it from a control
plane you host, and runs it on device through a sandboxed interpreter. One
screen becomes patchable; the rest of the app stays native.

**Read this whole file before running anything.** Several steps are hard to undo
(a promoted patch reaches real users; a lost signing key cannot be replaced
without a store release).

---

## 0. Ask exactly three things

Ask these together, in one message, before writing any code. They are the only
things you genuinely cannot work out for yourself — and each has a wrong answer
that causes an outage rather than a compile error.

### Q1. How many screens should be patchable, and which ones?

Each patchable screen becomes a **channel** — one app id, one signing key, one
entry on the dashboard, with a surface per screen. The control plane keys the
live bundle on `(appId, channel, env)`, so channels promote and roll back
independently and never overwrite each other.

Get the count and the names now; you will use them for `--channel` in §8 and
`channel:` on each `EjenixPatchView`.

Start with one screen unless the user asks otherwise. A patch replaces one
widget subtree — routing, navigation, state, and networking stay native.

### Q2. Where should the control plane run?

Offer the real options and let them pick:

| Answer | Command | Use when |
|---|---|---|
| Local / their own box | `./deploy.sh --target docker` | Evaluating, or self-hosting on a VM |
| Google Cloud | `./deploy.sh --target gcp --bucket <name>` | Durable storage, Cloud Run |
| Azure | `./deploy.sh --target azure --resource-group <g> --storage-account <a>` | Durable storage |
| AWS | `./deploy.sh --target aws --ephemeral` | Evaluation only — App Runner has **no persistent volume**, so uploads are lost on restart |
| Kubernetes | `./deploy.sh --target kubernetes` | They already run a cluster |
| Bare metal | `sudo ./deploy.sh --target bare-metal` | A Linux host with systemd |
| Already running one | — | Take the URL **and its admin token** — every command from §4 on authenticates, so a URL alone leaves you stuck at 401 |

If they pick AWS, say plainly that it is not durable and offer ECS/Fargate with
EFS, or `bare-metal` on EC2, as the durable alternative.

### Q3. Confirm the app id

**Detect it, then confirm — do not ask blind.** Read `applicationId` from
`android/app/build.gradle.kts` (or `build.gradle`), or `PRODUCT_BUNDLE_IDENTIFIER`
from the Xcode project, and propose it.

It must match in three places, permanently: `EjenixPatchView(appId:)`,
`ejenix build --app-id`, and `ejenix app create --id`. A mismatch shows up as a
silently rejected patch, not an error.

---

### Do not ask about these — decide them yourself

Asking these wastes the user's time; each has one correct answer.

| Don't ask | Just do this |
|---|---|
| Where to store the signing key | Write it to the project root, add `*.key` to `.gitignore` **in the same step**, and tell them to move the private seed into their CI secret store before their first real release |
| Which environment to target first | Always `staging`. Only `production` after they explicitly say so |
| What to show if no patch runs | The screen you are replacing. It already exists — wire it into `fallbackBuilder` |
| Whether they want signature verification / a sandbox / rollback | These are not optional and cannot be turned off |
| Whether to commit the key | Never. Not a question |
| Permission to read their code | You are already integrating it |

### Confirm before each of these, every time

Not once at the start — these are not undone by re-running the command.

- **`ejenix promote --env production`** — this reaches real users immediately.
  `--env` is required on both `promote` and `rollback` (the CLI refuses without
  it rather than assuming production), so the target is always visible in the
  command you are about to run. Confirm before any promote to production.
- `./deploy.sh --target aws|gcp|azure|kubernetes` — creates billable resources.
- Overwriting an existing `*.key` — destroys a signing key. Installs signed by
  it can never be patched again without a store release.

---

## 1. Preflight

```bash
flutter --version          # Flutter 3.x with Dart 3.x
dart --version
```

Install the CLI from a clone of this repo:

```bash
git clone https://github.com/ejenix/opensource.git
cd opensource
dart pub get
dart pub global activate --source path packages/cli
export PATH="$PATH:$HOME/.pub-cache/bin"
ejenix --version
```

Two directories are in play from here on, and mixing them up is the most common
way this goes wrong:

- **the clone** — where `./deploy.sh` and `flutter_bridge/patch_sdk/` live (§2, §6);
- **the user's app** — where every `ejenix` command runs (§3 onward).

Note the clone path; you will come back to it. Then, from the **user's app
directory**:

```bash
ejenix doctor
```

`doctor` is a light check — it confirms the Dart toolchain and, if you pass
`--signing-key <path>`, that the key parses. It will not catch a missing patch
SDK, a wrong app id, or an unreachable control plane. Do not treat a clean
`doctor` as an integration check; the §14 checklist is the real one.

---

## 2. Run the control plane

The control plane stores and serves patches. **It is never trusted to authorize
code** — devices verify signatures themselves — so a compromised server cannot
run anything on a device. It still needs to be online for updates to arrive.

```bash
./deploy.sh --target docker              # local / a box you own
```

Other targets: `kubernetes`, `aws`, `gcp`, `azure`, `bare-metal`. The four cloud
targets accept `--dry-run` to print the plan first; `docker` and `kubernetes`
reject `--dry-run` rather than ignoring it.

It prints two secrets, and only on the run that generates them:

- `EJENIX_ADMIN_KEY` — operator token for the CLI and dashboard.
- `EJENIX_DELIVERY_SEED` — keep it stable across restarts.

For `--target docker` they are also written to `deploy/docker/.env` (mode 0600)
and re-read on later runs, so they are recoverable there. For the cloud targets
treat the printed values as the only copy.

Export the token so you never pass it on a command line:

```bash
export EJENIX_TOKEN="<the admin key>"
```

Verify the server is up before continuing:

```bash
curl -fsS http://localhost:8080/v1/health
```

---

## 3. Generate the signing key

```bash
ejenix keygen -o release.key
```

This writes `release.key` (private seed, `0600`) and `release.key.pub`.

- **`release.key` must never be committed.** Add `*.key` to `.gitignore` now.
- Put the private seed in the user's CI secret store.
- `release.key.pub` is public — it goes into the app and the control plane.

---

## 4. Register the app — once, whatever the screen count

**One app id for the whole app**, however many screens are patchable. Screens
are separated by channel, not by app id.

```bash
ejenix app create --id com.acme.shop --name "Acme Shop" \
  --key release.key.pub --server http://localhost:8080
```

Channels need no registration — naming one on `promote` creates it. Each screen
passes its own `channel:` to `EjenixPatchView` and promotes and rolls back
independently.

```bash
ejenix app list --server http://localhost:8080     # confirm what registered
```

**`app create` prints a third secret** — an *app API key*, shown once, which
authorizes that one app. The server stores only its hash, so it cannot be
recovered. Capture it per app and put it in the §14 handoff. It is the
least-privilege token for CI: prefer it over the admin key, which authorizes
every app on the control plane.

The id must be identical in three places, permanently: `ejenix app create --id`,
`EjenixPatchView(appId:)`, and `ejenix build --app-id`. A mismatch is a silently
rejected patch, not an error.

---

## 5. Add the SDK to the app

In the user's `pubspec.yaml`:

```yaml
dependencies:
  ejenix_flutter:
    git:
      url: https://github.com/ejenix/opensource.git
      path: flutter_bridge
  path_provider: ^2.1.0
```

Then `flutter pub get`.

---

## 6. Scaffold each patchable screen

Run this once per screen, with that screen's own app id:

```bash
ejenix scaffold home_screen --app-id com.acme.shop
ejenix scaffold checkout_screen --app-id com.acme.shop   # same app id
```

Then set `channel:` on each generated view — `'home'`, `'checkout'` — so they
do not share a slot.

This writes two files:

- `patches/home_screen.dart` — the interpreted screen (this is what ships OTA).
- `lib/home_screen_view.dart` — the native host widget wrapping
  `EjenixPatchView`.

The generated host **already wires** `cacheDir`, `bundledFallback`,
and `fallbackBuilder` for you. Your job is the four `TODO` markers it leaves:

| Line | TODO | What to put there |
|---|---|---|
| `_trustedKeys` | Ed25519 public key bytes | The bytes of `release.key.pub`. **It is an empty list by default, and an empty trust anchor rejects every patch** — silently, showing only the fallback. This is the #1 cause of "my patch never arrives". |
| `controlPlane:` | `https://your-control-plane.example` | The real URL from §2 |
| `appId:` | already filled from `--app-id` | Verify it matches §4, then delete the marker |
| `env:` | `'staging'` | **Check this against what you promote to.** It defaults to `'production'` if absent, so a view on `production` never sees a bundle promoted to `staging` — silently, with no error anywhere |
| `extend:` | commented out | Uncomment after §7 and pass `appCapabilities(...)` |

Two more things the scaffold cannot do for you:

- **Replace the placeholder fallback.** `_fallback()` renders "Running the
  built-in screen." Swap in the real native screen you are replacing.
- **Register the bundled asset** in the app's `pubspec.yaml`, or
  `bundledFallback` is silently `null` and the first launch has no screen until
  the network answers:

  ```yaml
  flutter:
    assets:
      - assets/home_screen.bundle
  ```

  You also have to *put a bundle there*. Nothing in §8 does it — that builds to
  `home.bundle` in the working directory. After the first successful build:

  ```bash
  mkdir -p assets && cp home.bundle assets/home_screen.bundle
  ```

  Refresh it whenever you want the binary to ship a newer starting patch.

### Install the patch SDK — required, or nothing compiles

The scaffolded patch begins:

```dart
import '../patch_sdk/flutter.dart';
import '../patch_sdk/app.dart';
```

`scaffold` does **not** create either file. Without them `ejenix build` fails
with `The function 'Scaffold' isn't defined` and a dozen similar errors, which
looks like a broken patch and is actually a missing SDK.

- `patch_sdk/flutter.dart` is **copied** from this repo — it is the typed
  surface of every widget the bridge exposes:

  ```bash
  mkdir -p patch_sdk
  cp <path-to-ejenix-clone>/flutter_bridge/patch_sdk/flutter.dart patch_sdk/
  ```

- `patch_sdk/app.dart` is **generated** by `ejenix gen` in §7. Until you have
  `@Patchable` code, write a placeholder so the import resolves:

  ```dart
  // patch_sdk/app.dart — replaced by `ejenix gen` in §7.
  ```

Re-copy `flutter.dart` whenever you upgrade the `ejenix_flutter` dependency: it
is a snapshot of the bridge's surface, and a stale copy lets a patch compile
against widgets the installed binary no longer exposes.

For reference, `EjenixPatchView` requires four things — `controlPlane`, `appId`,
`trustedKeys`, `cacheDir` — and defaults the rest. Note `cacheDir` is a
`Directory`, not a `Future`: `await getApplicationSupportDirectory()` cannot go
inline in a synchronous `build()`. Resolve it first, which is why the scaffold
wraps everything in a `FutureBuilder`. Use the scaffolded file rather than
retyping this.

```dart
EjenixPatchView(
  controlPlane: Uri.parse('http://localhost:8080'),  // required
  appId: 'com.acme.shop',                            // required
  channel: 'home',                                   // this screen's surface
  trustedKeys: [_publicKeyBytes],                    // required
  cacheDir: boot.cacheDir,                           // required — already awaited
  env: 'staging',                                    // defaults to 'production'
  extend: appCapabilities(repo),
  bundledFallback: boot.fallback,
  fallbackBuilder: (context, error) => const NativeHomeScreen(),
  onStatus: (status) => debugPrint('$status'),
)
```

**Never remove `fallbackBuilder`.** The scaffold sets it. Without it the user
does not get an error — they get *nothing*: a failed patch renders
`SizedBox.shrink()`, a blank hole where the screen was, and a first launch with
no cached or bundled patch sits on a `CircularProgressIndicator` that never
resolves. No crash, no message, no clue. It is the single most important line in
the integration.

Then place `HomeScreenView()` where the old screen was.

---

## 7. Expose capabilities the patch needs

A patch can only call what the **installed binary** registers. It cannot bring
new capabilities with it.

Mark real code in the user's app:

```dart
import 'package:ejenix_flutter/ejenix_flutter.dart';

@patchable                          // exposed to patches as `PrimaryButton`
class PrimaryButton extends StatelessWidget { /* ... */ }

class ProductRepository {
  @Patchable('App.products')        // exposed as `App.products`
  List<Product> products() { /* ... */ }
}
```

Generate both sides:

```bash
ejenix gen lib/design_system.dart lib/product_repository.dart \
  --out-sdk patch_sdk/app.dart \
  --out-capabilities lib/app_capabilities.g.dart
```

Pass the generated `appCapabilities(...)` to `EjenixPatchView(extend:)`.

Arguments must be marshalable — `String`, `int`, `double`, `num`, `bool`,
`Object?`, a `Widget`, or a 0-/1-argument callback. Anything else is a build
error, not a runtime surprise.

---

## 8. Ship the first patch

```bash
# 1. compile + sign
ejenix build patches/home_screen.dart -o home.bundle \
  --signing-key release.key --app-id com.acme.shop

# 2. verify offline before it leaves the machine
ejenix verify home.bundle --key release.key.pub

# 3. upload
ejenix push home.bundle --server http://localhost:8080 --app com.acme.shop

# 4. make it live — CONFIRM WITH THE USER FIRST if env is production
ejenix promote <bundle-id> --channel home --env staging \
  --server http://localhost:8080 --app com.acme.shop
```

### Ship it to a slice first

`--rollout <percent>` exposes a patch to part of the fleet. Each device decides
locally whether it is in the share, so nothing is reported back and no device
registry exists.

```bash
ejenix promote <id> --channel home --env production --rollout 5    # canary
ejenix promote <id> --channel home --env production --rollout 100  # widen
```

Widening keeps the same devices and adds more — re-promoting the *same* bundle
at a higher percentage never drops an install that already had it. Use this for
anything risky: at 5%, a bad patch is caught by devices rolling themselves back
before the other 95% ever see it.

A `rollback` always restores the previous bundle to **100%** of devices.

`push` prints the `bundle-id` that `promote` needs.

Rolling back — restores whatever was active before the last promote:

```bash
ejenix rollback --channel home --env staging \
  --server http://localhost:8080 --app com.acme.shop
```

**Rollback needs somewhere to go.** After a single promote there is no previous
bundle, and the control plane answers `409: no previous bundle to roll back to`.
That is correct, not a fault. To exercise rollback you need two promotes.

**It is a two-slot toggle, not a stack.** Rollback swaps active and previous, so
running it twice puts you back where you started rather than stepping further
back through history. To reach an older release, `promote` its bundle id
directly.

### Verify it actually worked

Do not report success until you have seen it. Run the app, then confirm via
`onStatus`, which reports one of:

| Status | Meaning |
|---|---|
| `cached` | Ran the previously downloaded patch |
| `bundled` | Ran the patch shipped inside the binary |
| `updated` | **Fetched and ran a newer patch — this is what you want** |
| `upToDate` | Nothing new was staged. **This also covers "could not reach the control plane" and "the fetch failed"** — it is not proof the device is current. If you are debugging a patch that never arrives, do not read this as success |
| `rejected` | The bundle was refused before running: bad signature, untrusted key, wrong `targetAppId`, **or a `--min-sdk` above this build's `sdkVersion`** |
| `rolledBack` | Crash-looped and reverted itself |
| `incompatible` | The patch ran but cannot run *here*: a missing capability, a `build()` that returned a non-Widget, or an instruction-budget overrun — see §10 |

---

## 9. Before they ship to a public app store

Tell the user this explicitly; do not decide it for them.

Ejenix constrains *what a patch can reach*. It cannot judge whether a change
stays inside the app that was reviewed — that judgment is theirs on every
promote.

- **Lower risk:** fixing a broken screen, copy, layout, content, reordering a
  flow whose screens were all reachable at review.
- **Do not:** ship a feature hidden at review time, unlock functionality after
  approval, change what the app is for, or route users to purchase paths outside
  what was submitted.

A reviewer's device fetches the active patch like any other user, so what is
live during review is part of what is reviewed. Use a separate `env` for review
builds, or freeze promotes during the review window.

Full detail, with the actual clause text:
[`docs/production.md` → Store review and interpreted code](docs/production.md#store-review-and-interpreted-code).

---

## 10. Rules you must not break

These cause fleet-wide outages, not local errors.

1. **Never publish a patch that uses a capability the shipped binary lacks.**
   Adding `@Patchable` and regenerating makes it compile — but the build in the
   store predates it. Bump `sdkVersion` in the app when adding a capability, and
   stamp patches that need it with `ejenix build --min-sdk <version>`. The
   loader rejects under-floor patches before staging.

   Gate it in CI:

   Write this test — it must run under `flutter test`, because
   `capabilityManifest` imports `package:flutter` and plain `dart run` cannot
   compile it (it dies inside the FFI transformer with an error that never
   mentions Flutter):

   ```dart
   // test/dump_capabilities_test.dart
   import 'dart:io';
   import 'package:ejenix_flutter/ejenix_flutter.dart';
   import 'package:flutter_test/flutter_test.dart';
   import '../lib/app_capabilities.g.dart';

   void main() => test('dump the capability surface', () {
     Directory('build').createSync(recursive: true);
     File('build/capabilities.json')
         .writeAsStringSync(capabilityManifest(appCapabilities(repo)));
   });
   ```

   ```bash
   flutter test test/dump_capabilities_test.dart
   ejenix verify home.bundle --key release.key.pub \
     --capabilities build/capabilities.json     # exit 65 if unrunnable
   ```

   The manifest must come from the **app**, via `capabilityManifest(extend)` —
   not from the CLI, which cannot see the Flutter bridge's own surface.

2. **A signature change is a breaking change.** The gate matches capability
   *names*, not shapes. Renaming a parameter or making one required passes every
   check and then fails on device. Treat it like a new capability.

3. **The app must work with no patch at all.** `fallbackBuilder` plus a
   `bundledFallback` asset. Verify by launching with the control plane
   unreachable.

4. **Never commit `*.key`.** Check `.gitignore` before the first commit.

5. **Never move the trust anchor to the server.** Devices trust the key compiled
   into the binary. Do not add a code path that accepts keys fetched at runtime.

6. **Patches are a subset of Dart.** See [`spec/dart-subset.md`](spec/dart-subset.md).
   The subset is wide (classes, generics, mixins, records, patterns, async,
   generators), but `dart:io`, `dart:ffi`, `dart:mirrors`, and `dart:isolate`
   are permanently forbidden inside the sandbox.

7. **Don't raise `stepLimit` to "fix" a slow patch.** The budget exists so a
   patch that loops forever falls back instead of freezing the app. If a patch
   hits it, the patch is wrong.

---

## 11. When something fails

| Symptom | Cause | Fix |
|---|---|---|
| `onStatus` → `rejected` | Wrong signing key, or `--app-id` ≠ `appId` | Re-check both; `ejenix inspect <bundle>` shows what it targets |
| `onStatus` → `incompatible` | Patch needs a capability this build lacks | Ship a binary that registers it; use `--min-sdk` to keep the patch off older installs |
| `onStatus` → `rolledBack` | Patch crash-looped | Read the error in `fallbackBuilder`; the device already recovered |
| `MissingHostCapabilityException` | Same as `incompatible`, at the exact call | The message names the selector |
| `StepLimitExceededException` | Patch loops or does unbounded work | Fix the patch; do not raise the budget |
| 401 from the control plane | No/incorrect token | `export EJENIX_TOKEN=...` |
| 409 on `push` | That bundle id already exists with different bytes | Build a new bundle; ids are immutable by design |
| 409 on `rollback` | Only one bundle has ever been promoted to that env | Expected. There is nothing behind the current one |
| `The function 'Scaffold' isn't defined` when building a patch | `patch_sdk/flutter.dart` is missing | Copy it — see §6 "Install the patch SDK" |
| Patch verifies and promotes, device only ever shows the fallback | `_trustedKeys` is still the empty list the scaffold leaves | Fill it with the `release.key.pub` bytes |
| Patch compiles but device shows the fallback | Almost always #1 or #2 above | Check `onStatus` first — it names the cause |

---

## 12. Local development loop

For iterating on a patch without pushing to a control plane:

```bash
ejenix watch patches/home_screen.dart --app-id com.acme.shop \
  --signing-key release.key
```

`--signing-key` is **required** — omitting it exits 64.

**Read this before you promise the user live reload.** The watch server speaks
its own protocol — it serves `/patch.bundle`, `/events`, and `/health` — while
`EjenixPatchView` polls `/v1/apps/<app>/envs/<env>/active`. They do not
interoperate, so **a screen scaffolded by §6 will not pick up watch builds.**

Live reload against a scaffolded screen needs a hand-written SSE client feeding
`InterpretedView` instead of `EjenixPatchView` — see
[`example/patchable_app/lib/patch_channel.dart`](example/patchable_app/lib/patch_channel.dart),
which is ~200 lines and is how the example does it.

Unless the user asks for that, iterate with `build → push → promote --env
staging`. It is slower per cycle but it is the path you just wired, and it
exercises the real signature and rollback machinery.

---

## 13. Reference

- [`docs/getting-started.md`](docs/getting-started.md) — the human walkthrough.
- [`docs/production.md`](docs/production.md) — hosting, capability
  compatibility, hang budget, store policy.
- [`example/patchable_app/`](example/patchable_app/README.md) — a complete,
  tested integration, and the best reference for capabilities, `ejenix gen`, and
  the patch SDK layout. **Note it wires the lower-level `InterpretedView` plus a
  hand-written dev-server channel, not `EjenixPatchView`** — so copy its
  capability and build wiring, not its view layer. The `EjenixPatchView` shape
  you want is what `ejenix scaffold` emits.
- [`spec/dart-subset.md`](spec/dart-subset.md) — exactly what a patch may use.
- [`docs/errors/`](docs/errors/README.md) — every compiler diagnostic by code.

---

## Checklist before you tell the user you are done

- [ ] Control plane reachable; `/v1/health` returns ok
- [ ] App registered; `ejenix app list` shows it
- [ ] `*.key` in `.gitignore`; private seed not in the repo
- [ ] `fallbackBuilder` set on `EjenixPatchView`
- [ ] App launches correctly with the control plane **unreachable**
- [ ] A patch was built, verified, pushed, promoted, and `onStatus` reported
      `updated` on a real run
- [ ] `patch_sdk/flutter.dart` copied in, and `patch_sdk/app.dart` generated
- [ ] `_trustedKeys` filled in — **not** the empty list the scaffold leaves
- [ ] Rollback tested (needs two promotes; one promote gives a correct 409)
- [ ] The user knows which `env` is live and what §9 means for their store
      submission

---

## 14. Hand back to the user — always finish with this

When everything on the checklist passes, print the block below **filled in with
real values**. Do not paraphrase it and do not leave placeholders: this is the
only record the user has of credentials you generated on their behalf, and
several are shown exactly once and stored only as hashes.

Say plainly, in the same message, that the block contains live credentials, that
the admin key authorizes every app on the control plane, and that they should
move it into a password manager and clear their scrollback. If the user has a
secret manager and asks you not to echo secrets, honour that and print the
storage location instead of the value.

If a value does not exist (no `bundledFallback`, only one screen, no CI yet),
write `—` rather than deleting the row.

```
════════════════════════════════════════════════════════════════════
  EJENIX IS LIVE
════════════════════════════════════════════════════════════════════

  CONSOLE
    Dashboard      https://<host>/            ← open this, paste the admin key
    Health         https://<host>/v1/health
    Hosted on      <docker on their VM | GCP Cloud Run | Azure | AWS App Runner
                    | Kubernetes | bare-metal systemd>

  CREDENTIALS — move these into a password manager or secret store NOW, then
  clear them from your terminal. The app API keys and the signing seed cannot
  be recovered; the server keeps only hashes.
    EJENIX_ADMIN_KEY       <value>   ← authorizes EVERY app. Operator use only
    EJENIX_DELIVERY_SEED   <value>
    App API key <app-id>   <value>   ← one per app id; least privilege, use in CI
    Signing key (private)  ./release.key      ← gitignored; move to CI secrets
    Signing key (public)   ./release.key.pub  ← safe to commit

  WHAT IS PATCHABLE
    App id  <com.acme.shop>   (one id; screens are separated by channel)
    <lib/home_screen_view.dart>   channel <home>       env <staging>   rollout <100%>
    <lib/checkout_view.dart>      channel <checkout>   env <staging>   rollout <100%>

════════════════════════════════════════════════════════════════════
  HOW TO SHIP A PATCH
════════════════════════════════════════════════════════════════════

  0. Once per shell — prefer the app API key over the admin key:
       export EJENIX_TOKEN='<app API key for this app id>'

  1. Edit the screen:
       patches/home_screen.dart

  2. Compile and sign:
       ejenix build patches/home_screen.dart -o home.bundle \
         --signing-key release.key --app-id <com.acme.shop>

  3. Check it before it leaves your machine:
       ejenix verify home.bundle --key release.key.pub

  4. Upload (prints the bundle-id you need next):
       ejenix push home.bundle --server https://<host> --app <com.acme.shop>

  5. Go live — --env is required; the CLI refuses without it:
       ejenix promote <bundle-id> --channel home --env staging \
         --server https://<host> --app <com.acme.shop>
     Add --rollout 5 to expose it to a slice of the fleet first.

     Devices pick it up on their next launch or resume, and only if their
     EjenixPatchView(env:) matches the env you promoted to.

  ROLL BACK — one command, restores the previous bundle:
       ejenix rollback --channel home --env staging \
         --server https://<host> --app <com.acme.shop>

  Steps 4 and 5 are also a dropdown and a Promote button on the dashboard.

════════════════════════════════════════════════════════════════════
  BEFORE YOU PROMOTE TO PRODUCTION
════════════════════════════════════════════════════════════════════

  · A patch may only call capabilities THIS SHIPPED BINARY registers. Adding a
    new @Patchable and rebuilding is not enough — the build in the store
    predates it. Ship the binary first, then the patch.

  · Test on `staging` against a real device build before promoting.

  · A patch must stay inside the app that was reviewed by Apple/Google.
    See docs/production.md → "Store review and interpreted code".

  · The app still works if the control plane is down or every patch fails —
    that is what fallbackBuilder is for. Keep it that way.
```

### Then say these three things in your own words

1. **Where the console is and how to log in** — the URL, and that the admin key
   is what the login box wants.
2. **What is now patchable and what is not** — name the screens, and say plainly
   that everything else still needs a store release.
3. **The one rule that breaks fleets** — a patch cannot use a capability the
   installed binary lacks. If they add one, the binary ships first.

Do not end the session without printing the block. An integration the user
cannot operate is not finished.
