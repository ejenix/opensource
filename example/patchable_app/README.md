# patchable_app — how to architect a Flutter app for over-the-air patches

A working Flutter app whose **home screen is an interpreted patch**: compiled to
bytecode, signed, and shipped over the air. Change `patches/home_screen.dart`,
re-run `build.sh`, and the screen changes on devices already in the field —
minutes instead of a release cycle.

A patch changes how fast you can fix that screen, not what the app is permitted
to do: it reaches only the capabilities this binary registers, and must stay
within the app that was reviewed. See
[Store review and interpreted code](../../docs/production.md#store-review-and-interpreted-code).

The point of this example is not that it renders. It is **where the line sits**.

```
┌─ the binary (App Store) ───────────────────┐
│  routes · design system · state · network  │   the app owns these
│  the public key it trusts                  │
│                                            │
│    ┌─ InterpretedView ─────────────────┐   │
│    │  home_screen.dart  (the patch)    │   │   ← replaceable over the air
│    │  layout · logic · copy            │   │
│    └───────────────────────────────────┘   │
└────────────────────────────────────────────┘
```

## Run it

```sh
./build.sh                                                  # gen + compile + sign the patch
flutter run --dart-define=PATCH_PUBKEY=$(cat keys/dev.key.pub)
flutter test                                                # 10 tests, incl. the security ones
```

### On a real device

The interesting run is a **release** build, because that is AOT-compiled and
tree-shaken — the environment a patch actually ships into, and the one a
JIT-mode test harness never exercises.

```sh
./build.sh
PUBKEY=$(cat keys/dev.key.pub)

# iOS — needs a signing team (Xcode ▸ Runner ▸ Signing & Capabilities).
# A free Apple ID works; give the app a bundle id nobody else has claimed.
flutter run --release -d <iphone> --dart-define=PATCH_PUBKEY=$PUBKEY

# Android
flutter run --release -d <android> --dart-define=PATCH_PUBKEY=$PUBKEY
```

The public key is compiled **into the binary** via `--dart-define`. That is the
root of trust: the app runs a patch only if it is signed by the matching private
key. Change the key and the same bundle stops being accepted — which you can see
for yourself:

```sh
# Sign a patch with a *different* key and watch the device refuse it.
dart run ../../packages/cli/bin/ejenix.dart keygen -o keys/attacker.key
dart run ../../packages/cli/bin/ejenix.dart compile patches/home_screen.dart \
  -o assets/home_screen.bundle --signing-key keys/attacker.key --app-id com.example.patchable_app
flutter run --release -d <device> --dart-define=PATCH_PUBKEY=$PUBKEY
```

The app falls back to the screen that shipped in the binary and tells you the
patch was rejected. It never interprets a byte of it. Restore the real patch with
`./build.sh`.

`build.sh` runs the real toolchain — the same `ejenix build` a team runs in CI.
The only thing missing versus production is the fetch: `ejenix push` would
upload the bundle to the control plane, and `package:ejenix_loader` would
download, verify, stage, and roll it back on a crash loop.

## The four files that matter

| File | Role |
| --- | --- |
| **`@Patchable` in `lib/app_state.dart` + `lib/design_system.dart`** | **The whole idea.** The app tags what a patch may reach — its design system, its state, its services — right on its own real code. |
| **`lib/app_capabilities.g.dart` + `patch_sdk/app.dart`** | *Generated* from those annotations by `ejenix gen`: the host bindings and the typed declarations a patch compiles against. One source, two files, no drift. |
| **`patches/home_screen.dart`** | The patch. Plain Dart. Compiled, signed, shipped. |
| **`lib/main.dart`** | Loads the bundle, **verifies the signature**, and only then interprets it. |

The two generated files are what a developer used to hand-write twice; here they
are written once, as annotations on code that already exists. `build.sh` runs
`ejenix gen` before every compile, so they can never fall out of sync.

## What a patch can and cannot do

A patch reaches the outside world through exactly two imports —
`patch_sdk/flutter.dart` (what the bridge exposes) and `patch_sdk/app.dart`
(what *this app* exposes). Everything else fails **at compile time**, with a
diagnostic naming the line. Nothing silently misbehaves on a user's phone.

**It can:** rebuild the screen's layout and logic, use the app's own
`PrimaryButton` and `StatCard`, read and mutate the app's todos, trigger the
app's sync, hold a real `TextEditingController`, navigate to routes the app
declared, and show snackbars and dialogs.

**It cannot:** reach the network on its own (`App.refresh()` asks the *app* to,
which keeps the URL, auth, and retry policy in the binary); navigate to a route
the app never declared; use a widget nobody registered; or touch `dart:io`,
`dart:ffi`, `dart:mirrors`, or `dart:isolate` — those are refused permanently by
the sandbox.

## Why state management is *not* a bridged package

There is no Provider/Riverpod/Bloc binding here, and there should not be. Those
are compile-time and codegen-heavy, and they are the wrong layer. The shipped
binary keeps ownership of state (`TodoRepository`), and hands the patch a narrow,
named door to it:

```dart
// lib/app_state.dart — the app tags its own method as reachable
@Patchable('App.addTodo')
void add(String title) { /* ... */ }
```

```dart
// patches/home_screen.dart — the patch just asks
App.addTodo(state.draft.text);
```

`ejenix gen` turns that one annotation into both the host binding and the
`external void addTodo(String title)` the patch compiles against. That is the
whole state-management story, and it is a feature: a patch cannot
corrupt state it does not own, and you can change the patch without ever
migrating a store.

## Security, demonstrated not asserted

`test/patch_test.dart` proves the properties rather than claiming them:

- a patch signed by the **trusted key** runs;
- a patch signed by **another key** is rejected and **never interpreted** — this
  is the defence against a compromised update server;
- a **tampered** bundle is rejected;
- and a capability **declared but not registered** fails the build, so it can
  never fail on a user's device instead.

If no valid patch is available, the app falls back to the screen that shipped in
the binary. An over-the-air patch system must always have that: the binary alone is a
working app.
