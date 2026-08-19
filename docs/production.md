# Production live updates

How to run your own Ejenix control plane and push updates to your users' apps in
real time. End to end: **deploy the server → add the SDK → ship a patch**. No
third-party service, no per-seat pricing — it is your infrastructure and your
signing key.

The trust model in one line: **a device runs a patch only if it is signed by a
key your app was built to trust.** The control plane stores and serves patches;
it is never trusted to authorize code. So even a fully compromised server cannot
run anything on your users' devices.

---

## 1. Deploy the control plane

```sh
git clone https://github.com/ejenix/opensource.git
cd opensource
./deploy.sh --target docker          # local / a box you own
```

Or deploy it somewhere real — every target executes, and on the four cloud
targets `--dry-run` prints the plan first (with secrets redacted). `docker` and
`kubernetes` exec straight into their own tooling, so they reject `--dry-run`
rather than accepting it and deploying anyway:

```sh
./deploy.sh --target gcp   --bucket my-ejenix-data
./deploy.sh --target azure --resource-group ejenix-rg --storage-account ejenixdata
./deploy.sh --target aws   --ephemeral        # App Runner has no volumes
sudo ./deploy.sh --target bare-metal
./deploy.sh --target kubernetes
```

Set two secrets before it serves traffic (see [`deploy/README.md`](../deploy/README.md)).
Any target generates and prints them if you do not:

- `EJENIX_ADMIN_KEY` — the operator token (dashboard + CLI auth).
- `EJENIX_DELIVERY_SEED` — a stable 32-byte hex seed so the delta-signing key
  survives restarts.

Open the server root (`http://your-host:8080/`) for the **dashboard**: paste the
admin key and you can see every app, promote a bundle to an environment, and roll
back — from the browser.

## 2. Register your app and its signing key

Generate a signing key (keep the private half in your CI secret store — never in
the repo):

```sh
ejenix keygen -o release.key
```

The private seed is written `0600` (owner read/write only) through a temporary
file that is restricted *before* the key is written to it, then renamed into
place — so it is never on disk readable by anyone else, even briefly, and a
crash mid-write cannot leave a truncated key. On a filesystem that ignores
permission bits, `keygen` refuses rather than writing an unprotected key. The
`.pub` file stays readable; it is meant to be.

This is the one secret in the system that cannot be revoked: devices trust it
because it was compiled into the binary they shipped with, so replacing it means
a store release.

Register the app on the control plane with the **public** key it should trust —
either from the dashboard's **New app** form, or with the CLI:

```sh
ejenix app create --id com.myapp --name "My App" \
  --key release.key.pub \
  --server http://your-host:8080 --token $EJENIX_ADMIN_KEY
```

`--key` takes the `.pub` file (or the hex directly). `ejenix app list` shows what
is registered.

### Supplying the token without leaking it

`--token $EJENIX_ADMIN_KEY` is shown throughout this guide because it reads
clearly, but a token in an argument is recorded in your shell history and is
readable from the process list by any local user while the command runs. Neither
can be undone afterwards.

Every command that authenticates accepts three safer sources, and prefers them
over `--token`:

```sh
export EJENIX_TOKEN=...                 # what a CI secret store should set
ejenix app list --server https://your-host:8080

ejenix promote <id> --env production --token-file ~/.ejenix/token
op read "op://vault/ejenix/token" | ejenix push home.bundle --token-stdin
```

`EJENIX_ADMIN_KEY` is accepted as well as `EJENIX_TOKEN`, so the value
`deploy.sh` prints works directly. `--token` still works and always will — it
just warns.

## 3. Add the SDK to your app

Depend on the Flutter bridge and `path_provider`:

```yaml
dependencies:
  ejenix_flutter:
    git: { url: https://github.com/ejenix/opensource.git, path: flutter_bridge }
  path_provider: ^2.1.0
```

Drop [`EjenixPatchView`](../flutter_bridge/lib/ejenix_patch_view.dart) in wherever the
screen you want to make patchable lives. It renders the cached patch instantly,
checks the control plane on launch and on resume, swaps in a newer **verified**
patch, and auto-rolls-back on a crash loop — all offline-first and fail-soft:

```dart
EjenixPatchView(
  controlPlane: Uri.parse('https://your-host:8080'),
  appId: 'com.myapp',
  env: 'production',
  trustedKeys: [_publicKey],               // the release.key.pub bytes
  cacheDir: await getApplicationSupportDirectory(),
  bundledFallback: await rootBundle        // the patch you ship in the binary
      .load('assets/home.bundle')
      .then((d) => d.buffer.asUint8List()),
  extend: appCapabilities(repo),           // your widgets, state, services
  fallbackBuilder: (context, error) => const NativeHomeScreen(),
)
```

The only app-side wiring is: the public key it trusts, a cache directory, and
what capabilities the patch may use (`extend` — see
[`example/patchable_app`](../example/patchable_app/README.md)). Everything the
patch can't reach fails at **compile time**, never at runtime on a device.

### Let codegen write the capability plumbing

A capability otherwise has to be declared twice — as an `external` in the patch
SDK, and as a `registerGlobal` binding in `extend`. Skip that: mark the real
thing with `@Patchable` and run `ejenix gen`, which writes **both** from your
own code.

```dart
import 'package:ejenix_flutter/ejenix_flutter.dart';

@patchable                       // exposed to patches as `PrimaryButton`
class PrimaryButton extends StatelessWidget { /* ... */ }

class TodoRepository {
  @Patchable('App.addTodo')      // exposed as `App.addTodo`
  void add(String title) { /* ... */ }
}
```

```sh
ejenix gen lib/design_system.dart lib/app_state.dart \
  --out-sdk patch_sdk/app.dart \
  --out-capabilities lib/app_capabilities.g.dart
```

That generates `patch_sdk/app.dart` (what patches compile against) and
`appCapabilities(...)` (what you pass to `EjenixPatchView(extend:)`). Inputs must
be plain marshalable types — `String`, `int`, `bool`, a `Widget`, or a
0-/1-argument callback — and a type that can't cross the sandbox is a build
error, not a silent runtime failure.

### Or scaffold the whole screen in one command

To skip the boilerplate entirely, generate the patch stub and the wired host:

```sh
ejenix scaffold home_screen --app-id com.myapp
```

That writes `patches/home_screen.dart` (the interpreted screen you edit) and
`lib/home_screen_view.dart` (a `HomeScreenView` widget that already wraps
`EjenixPatchView` with the cache directory, update-on-resume, and crash-loop
rollback). Fill its `TODO`s — trusted key, control-plane URL, app id, `env:`,
and `extend:` from `ejenix gen` — drop `HomeScreenView()` in your tree, and you
are at step 4.

The scaffolded patch imports `../patch_sdk/flutter.dart`, which is **copied, not
generated**. Without it every build fails with `Target of URI doesn't exist`:

```sh
mkdir -p patch_sdk
cp <ejenix-clone>/flutter_bridge/patch_sdk/flutter.dart patch_sdk/
```

Re-copy it whenever you upgrade `ejenix_flutter` — it is a snapshot of the
bridge's surface, and a stale copy lets a patch compile against widgets the
installed binary no longer exposes.

## 4. Ship a patch — live

Write the screen as an interpreted patch (plain Dart against your patch SDK),
then:

```sh
ejenix build lib/patches/home.dart -o home.bundle \
  --signing-key release.key --app-id com.myapp

ejenix push home.bundle --server https://your-host:8080 \
  --app com.myapp --token $EJENIX_ADMIN_KEY

ejenix promote <bundle-id> --env production \
  --server https://your-host:8080 --app com.myapp --token $EJENIX_ADMIN_KEY
```

The moment you promote, every device picks it up on its next launch or resume —
minutes instead of a release cycle, and no reinstall for the user. Prefer the
dashboard? Steps two and three are a dropdown and a **Promote** button.

This changes how fast a fix reaches users, not what your app is allowed to do:
a patch may only use capabilities the shipped build already registers, and must
stay within the app you submitted. See
[Store review and interpreted code](#store-review-and-interpreted-code).

`--env` is required on both `promote` and `rollback` — it is not defaulted,
because a release command should never assume its most destructive target.

Made a mistake? One button (or `ejenix rollback --env production …`) restores the
previous bundle, and devices that crash-loop on a bad patch roll themselves back
without you doing anything.

## The guarantees you keep

- **Signed and verified** — Ed25519 over a canonical CBOR body, checked on-device
  before a byte runs. A patch from an untrusted key is discarded, not run.
- **Offline-first** — the app always has a working screen (cache, then the
  bundled fallback, then your native `fallbackBuilder`).
- **Self-hostable** — the whole control plane is one AOT binary on infra you own.
- **Sandboxed** — a patch reaches the host only through the capabilities you
  granted; no `dart:io`, `ffi`, `mirrors`, or `isolate`.
- **Bounded** — every interpreted call runs under an instruction budget, so a
  patch that loops forever falls back and rolls back instead of freezing the
  app. See [When a patch hangs](#when-a-patch-hangs).

For the local dev loop (edit → see it on device in ~10 ms), see
[`docs/getting-started.md`](getting-started.md) §4 and `ejenix watch`.

## Capability compatibility

A patch may only call capabilities the **binary already on the device**
registers. Add `@Patchable('App.blogs')`, run `ejenix gen`, compile a patch
against the regenerated SDK, and that patch is valid source — but the build in
the store predates it, and the call cannot resolve there. Devices handle this
safely (below), but the point is to never publish such a patch.

### Set a capability floor with `--min-sdk`

This is the mechanism, and it already works end to end. `sdkVersion` is what
your app declares to [`EjenixPatchView`](../flutter_bridge/lib/ejenix_patch_view.dart); `minSdk` is what a patch demands. The
loader compares them **before staging** — an under-floor patch is rejected
before it is written to disk, per device, across the whole fleet.

So the discipline is:

1. **Bump `sdkVersion` in your app whenever you add a capability.**
2. **Stamp each patch with the floor it needs:**
   `ejenix build home.dart --min-sdk 2.1.0 …`

A v1.9 install then rejects a 2.1.0 patch and keeps running what it has, while
v2.1 installs take it. That is per-version targeting, with no extra machinery —
and it is the only thing that makes a fleet running many app versions safe.

### Catch it in CI, before publishing

Have the app print its own capability surface, then check the patch against it:

It has to run under `flutter test`, not `dart run`: `capabilityManifest`
transitively imports `package:flutter`, and the standalone Dart VM cannot
compile that (it fails inside the FFI transformer, with an error that does not
mention Flutter at all).

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

```sh
flutter test test/dump_capabilities_test.dart
ejenix verify home.bundle --key release.key.pub \
  --capabilities build/capabilities.json     # exit 65 if unrunnable
```

`ejenix inspect home.bundle` lists the same requirements for a human.

The manifest **must** come from the app, not the CLI: the real surface is the
`@Patchable` set plus everything the Flutter bridge registers, and only the app
can build that. A manifest of `@Patchable` names alone would reject every patch
that uses `Text()`.

### What the check does not cover

The gate matches capability **names**, not signatures. A capability whose *shape*
changed — `App.addTodo({String title})` becoming
`App.addTodo({String title, int listId})` — is still present in an older binary
under the same name, so it passes both the CI check and the device check, and
then drops the new argument or throws a cast inside the binding.

This is not checkable statically: a host capability is registered as
`Object? Function(Object?, List<Object?>)`, so the registry does not know its own
parameter names, and the value a patch passes is an opaque map.

**Treat a signature change as a breaking change** — bump `sdkVersion` and set
`--min-sdk` on patches that need the new shape, exactly as for a new capability.
Adding an optional parameter with a default is safe; renaming, removing, or
making one required is not.

### What a device does if one slips through

Nothing crashes and no user sees a red screen:

1. The patch renders until it touches the missing capability, then the screen
   falls back to your `fallbackBuilder`.
2. It is **quarantined** — recorded on disk, so a control plane that keeps
   serving it cannot re-activate it on the next launch.
3. The loader **rolls back** to the last patch that worked.
4. `onStatus` reports `PatchStatus.incompatible`, so you can alert on it.

Only a missing capability triggers that. A transient fault shows the fallback
for a frame and keeps the patch — losing a working patch over a one-off would
be its own outage.

## When a patch hangs

A hang is the one failure the crash-loop rollback cannot see. An accidental
`while (true)` in a patch spins the UI thread: the app stops responding, but
nothing *crashes*, so nothing is recorded, no rollback fires, and the same patch
runs again on the next launch. Rolling back on the server does not help — a
frozen app never fetches anything.

So every interpreted call runs under an instruction budget
(`kDefaultPatchStepLimit`, 5,000,000). Overrunning it raises
`StepLimitExceededException`, which is handled like any other unrunnable patch:
the screen falls back, the bundle is quarantined, and the device rolls back to
the last patch that worked.

Two properties make that safe to leave on:

- **A patch cannot swallow it.** The fault propagates past interpreted `catch`,
  so a patch that wraps its own loop in a handler still stops.
- **It is deterministic.** The budget counts instructions, not milliseconds, so
  a patch behaves identically on a slow phone and a fast one. That is why an
  overrun is treated as permanent — retrying would re-enter the same loop.

The budget is charged per **logical invocation** — one call in from the host —
and spans everything beneath it: every `await` resume, every nested interpreted
async call, and every generator turn. So `while (true) { await tick(); }` is
bounded, and so is draining an endless `sync*` with `.toList()`.

The practical consequence: a very long lazy sequence consumed inside a single
call is charged to that one budget. At the default this is millions of
instructions and no real screen approaches it, but if you iterate something
genuinely huge in one `build()`, raise `stepLimit` rather than assuming each
turn is metered separately.

The default sits about two orders of magnitude above a complex `build()`, and an
`itemBuilder` is charged per row, each row a separate call with its own budget.
Raise it with `stepLimit:` if a patch legitimately does heavy work in one call;
set it to `null` only if you control every patch and accept that a loop is then
unrecoverable on the device.

### What the budget does not cover

Be precise about the boundary, because the budget counts **interpreted
instructions** and a single instruction can hand control to native Dart, which
the interpreter cannot preempt.

The built-ins that could allocate or consume without bound carry their own
ceilings — `'x' * n` is refused past `kMaxHostStringLength`, and draining an
iterable is refused past `kMaxHostElements`, both raising
`HostBudgetExceededException`. That covers `HostRegistry.standard()`.

**It does not cover the capabilities your app registers.** A capability you
expose through `@Patchable` or `extend:` runs as ordinary Dart with no budget:
if it sorts a million rows, performs a synchronous file read, or blocks, a patch
can invoke it for the cost of one instruction and the frame is gone. The
allow-list bounds *what* a patch may reach, not *how long* your own code takes
once reached. Treat every capability you expose as reachable from a hostile
patch, and bound the expensive ones yourself.

## Store review and interpreted code

Over-the-air updates sit next to a real App Store and Play policy question, and
adopters ask about it first. This section is what the software does, the clauses
it actually has to satisfy, and — the part that matters most — which condition
Ejenix cannot satisfy for you.

Clause text quoted here was checked against the Apple Developer Program License
Agreement dated **June 18, 2026**, and the App Store Review Guidelines and Google
Play policies as published on **2026-08-10**. Policy text changes — verify
against current wording for your own submission. This is engineering guidance,
not legal advice.

### What ships, and what moves

| Component | Where it lives |
|---|---|
| The interpreter | Compiled into your binary, submitted and reviewed with it |
| The capability allow-list | Compiled into your binary — a patch cannot widen it |
| The trusted public key | Compiled into your binary |
| The patch | Downloaded — Ejenix bytecode, read by the interpreter above |

What crosses the network is a signed bundle of bytecode operands. It is not
machine code, and not a `.dex`, `.jar`, `.so`, or `.dylib` — nothing is linked,
loaded, or handed to the OS as code. No import of `dart:ffi`, `dart:mirrors`, or
`dart:isolate`, and no use of `DynamicLibrary`, `dlopen`, `Process`, or
`MethodChannel`, appears in the interpreter, loader, or Flutter bridge. There is
no JIT and no **runtime** code generation — the interpreter is a `switch` over
[`Op`](../packages/bytecode/lib/src/opcode.dart) values. (`ejenix gen` generates
code at *build* time, on your machine; nothing is generated on the device.)

A patch reaches the host **only** through capabilities the shipped binary
registered (see [Capability compatibility](#capability-compatibility)). It
cannot open a socket, touch the filesystem, call a plugin, or reach an OS API
that your reviewed build did not already expose to it.

### Apple

The governing clause is **DPLA §3.3.1(B), "Executable Code"** — not §3.3.2,
which is Regulatory Compliance. Verbatim:

> Except as set forth in the next paragraph, an Application may not download or
> install executable code. Interpreted code may be downloaded to an Application
> but only so long as such code: (a) does not change the primary purpose of the
> Application by providing features or functionality that are inconsistent with
> the intended and advertised purpose of the Application (b) does not bypass
> signing, sandbox, or other security features of the OS; and (c) for
> Applications distributed on the App Store, does not create a store or
> storefront for other Applications.

Three conditions. Note what is **not** among them: there is no longer any
requirement that the interpreter be packaged in the app. That condition existed
in older versions of this agreement and is often still repeated second-hand; it
is gone. Ejenix bundles the interpreter anyway, and that is good engineering,
but do not treat it as the thing that makes you compliant.

Against the conditions Apple does impose:

- **(b) does not bypass signing, sandbox, or other OS security features** — the
  architecture speaks to this directly. Everything runs inside the app sandbox,
  in-process, as interpreted data. Nothing is dynamically linked, no code
  signature is created or circumvented, and no OS security boundary is touched.
- **(c) does not create a store or storefront** — satisfied by construction.
- **(a) does not change the app's primary purpose** — **Ejenix cannot help you
  here.** This is the load-bearing condition and it is entirely yours. See below.

**Guideline 2.5.2 is the harder one, and you should read it directly:**

> Apps should be self-contained in their bundles, and may not read or write data
> outside the designated container area, nor may they download, install, or
> execute code which introduces or changes features or functionality of the app,
> including other apps.

Read literally, 2.5.2 carries no interpreted-code exception of its own — its only
written carve-out is for educational apps. The DPLA grants the permission;
the Guideline states the limit. They resolve together the way they read: an
interpreter packaged in your reviewed binary is allowed, and what it must not do
is change the app's features or functionality out from under review.

That is precisely the line Ejenix is built to hold, and it is where the design
does the work — a patch reaches only capabilities the reviewed binary already
registered, so it cannot introduce functionality that was not there to review.
Keep patches inside the app you submitted and you are on the right side of both
clauses.

### Google Play

The Device and Network Abuse policy bars an app from updating itself outside
Play or downloading executable code, and carves out code "that runs in a virtual
machine or an interpreter where either provides indirect access to Android
APIs." It attaches a condition that matters:

> Apps or third-party code, like SDKs, with interpreted languages (JavaScript,
> Python, Lua, etc.) loaded at run time (for example, not packaged with the app)
> must not allow potential violations of Google Play policies.

That condition is the one the design is built for. A patch cannot *allow* a
policy violation the binary does not already permit: the trusted key is compiled
in, the reachable surface is fixed at build time, and every bundle is verified
before execution. Play's Malware policy draws its backdoor line at "arbitrary
code execution"; a channel whose signing key and reachable API surface are both
frozen at compile time is not that.

A compiled-in capability allow-list is exactly the mediation layer that carve-out
describes: a patch reaches Android only through host functions the reviewed
binary registered, and the set is fixed at build time. Apps built on Ejenix ship
on Google Play on that basis.

### The condition that is yours, not ours

Both stores ask, among other things, whether the update stays inside the app
that was reviewed. That is the question this design is organised around — but it
is not the only question a reviewer can act on, and satisfying it is not a
compliance result.

Ejenix constrains *what a patch can reach*. It cannot judge whether a screen
change is within your app's stated purpose. Nothing in the signing, verification,
or capability model stops you from patching a reviewed app into something else.
That judgment is yours on every promote.

**Where the line sits.** A useful rule of thumb: if a change would need release
notes, it needs a release. Everything short of that is what OTA is for.

- **Lower risk** — fixing a broken screen, correcting copy, adjusting layout,
  changing content or merchandising, reordering steps in a flow whose screens
  and outcomes were all reachable and exercisable in the submitted build.
- **Don't** — shipping a feature that was hidden or unreachable at review time,
  unlocking functionality after approval, changing what the app is for, or
  routing users to purchase paths outside what you submitted.

Note there is no "dark launch" entry on the first list. Enabling after approval
something a reviewer could not reach is the 2.3.1 case below, and the fact that
the code was compiled into the reviewed binary does not rescue it.

That second list is not risky *because* it is over-the-air. It is risky because
it is **hidden from review** — Guideline 2.3.1(a) is explicit: "Don't include
any hidden, dormant, or undocumented features in your app; your app's
functionality should be clear to end users and App Review." That applies
identically to a patch and to a flag flipped on your server after approval.

**Your privacy declarations travel with the patch.** App Privacy and Data Safety
describe what your app *does*, not what your binary *contains*. A patch that
adds a field, fires a new analytics event, or calls a capability reaching
personal data can make those declarations inaccurate with no binary change —
a store violation in its own right, and a GDPR/CCPA exposure independent of
either store. If a capability in your allow-list touches user data, changes to
how a patch uses it are a privacy review, not just a UI change. The same goes
for age rating and regional content rules: a content change can move you outside
both without touching the binary.

### At your next submission

A reviewer's device fetches the active patch for its environment like any other
user's. What is live during review is therefore part of what is reviewed.

Plan for that explicitly:

- Point review builds at a **separate `env`** whose active bundle you control
  (`ejenix promote <id> --env review`), or freeze promotes for the review window.
- Treat a patch that is live at review time as reviewed. Treat one you promote
  the day after approval as unreviewed.
- Keep the app shippable with patching disabled. `fallbackBuilder` and the
  bundled fallback already make the binary a working app on its own — that is
  the fallback position if a reviewer objects.

### Proven in review

Apps built on Ejenix are live on **both the App Store and Google Play**,
delivering patches to production users. The architecture has been through real
review on both platforms and cleared it.

That settles the question this section exists to answer — whether shipping an
interpreter and delivering it bytecode is compatible with the platforms' rules.
It is, and it is in production.

The one thing no architecture can decide for you is **what your patches
contain**. Review assesses your app: whether an update stays inside the product
you described, and whether anything was concealed at review time. Ejenix bounds
what a patch can *reach*; you decide what it *does*. Keep patches inside the app
you submitted — the guidance above is the whole of it — and the delivery
mechanism is not what a reviewer will take issue with.

### If a reviewer asks

These are the facts to have ready. A 2.5.2 objection is usually about what your
patch changed rather than how it was delivered, but these answer the
delivery-mechanism question precisely, and they have held up in a real review on
both stores:

- The interpreter, capability allow-list, and trusted key all ship in the
  reviewed binary; only bytecode moves.
- Nothing is dynamically linked or loaded; no OS security feature is touched
  (DPLA §3.3.1(B)(b)).
- Patches are Ed25519-verified against a key compiled into the app **before**
  execution — a compromised server cannot run anything on a device.
- `ejenix inspect <bundle>` prints the host capabilities a patch requires. That
  is an audit tool for you, and for anything you attach to a Resolution Center
  reply — reviewers have no way to run it themselves.
- The app is fully functional with no patch at all.

## Known limitations

Things worth knowing before you design around them, rather than discovering
mid-integration.

### A patch cannot add a capability

A patch only calls what the installed binary registers, so a capability must
ship in a release *before* any patch uses it. See **Capability compatibility**
above for the `--min-sdk` floor and the CI check that enforce it.

### Channels: one app, many patchable screens

An app usually has more than one screen worth patching. The control plane keys
the live bundle on `(appId, channel, env)`, so each screen gets its own
**channel** and they promote and roll back independently — one app id, one
signing key, one entry on the dashboard.

```sh
ejenix promote <id> --channel home     --env production --app com.acme.shop
ejenix promote <id> --channel checkout --env production --app com.acme.shop
```

```dart
EjenixPatchView(appId: 'com.acme.shop', channel: 'home', env: 'production', ...)
```

Channels need no registration; naming one on `promote` creates it. `channel`
defaults to `default`, which uses the pre-channel routes — so an app written
before channels existed keeps working with nothing to change and nothing to
migrate.

### Staged rollout

`--rollout <percent>` exposes a patch to part of the fleet:

```sh
ejenix promote <id> --channel home --env production --rollout 5     # canary
ejenix promote <id> --channel home --env production --rollout 40    # widen
ejenix promote <id> --channel home --env production --rollout 100   # everyone
```

**The device decides whether it is in the share.** The control plane publishes
a percentage and a salt; each install hashes its own local id against them and
answers for itself. Nothing is reported back, there is no device registry, and
the control plane has no way to target an individual install.

Three properties follow, and each is tested:

- **Stable** — an install's answer does not change between launches, so a patch
  does not appear and vanish.
- **Monotonic** — the salt is fixed for the life of a promotion, so re-promoting
  the same bundle at a higher percentage only ever *adds* devices. Nobody who
  had the patch loses it.
- **Even** — the spread lands within a few points of the requested share.

This is the feature that pairs with crash-loop rollback: at 5%, a bad patch is
caught by devices that roll *themselves* back before the other 95% ever see it.

A `rollback` always restores the previous bundle to **100%** of devices — a
partial rollback would leave the fleet split exactly when you need it whole.

### AWS App Runner is stateless

App Runner has no persistent-volume support, so `--target aws` requires
`--ephemeral` and uploaded bundles do not survive a restart. That is fine for
evaluation, or for a control plane your CI re-publishes into, but it is not a
durable production store. For durable AWS, run the same image on ECS/Fargate
with an EFS mount, or use `--target bare-metal` on EC2. GCP and Azure both
support real volumes — see [`deploy/cloud/README.md`](../deploy/cloud/README.md).
