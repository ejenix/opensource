# Getting started

From a fresh clone to a running patch — and to live updates on a real phone —
with the fewest commands possible. Copy-paste top to bottom.

## Prerequisites

- **Dart SDK ≥ 3.11** (the repo is developed on 3.12). Check: `dart --version`.
- **Flutter ≥ 3.44** — only for the Flutter example app (§4). Check: `flutter --version`.
- Nothing else. No database, no cloud account, no API key.

```sh
git clone https://github.com/ejenix/opensource.git
cd opensource
dart pub get
```

## 1. See it work — one command

The fastest proof the whole pipeline runs. Compiles a Dart patch, signs it,
verifies the signature, and executes it in the sandbox — no server, no device:

```sh
bash example/hello_patch/run.sh
```

```
✓ compiled 5 function(s) -> hello.bundle (751 bytes)
✓ signature and content integrity verified
✓ applied patch → main() = 226
```

That is compile → sign → **verify** → interpret, end to end, in under a second.

## 2. Install the `ejenix` CLI

So you type `ejenix …` instead of `dart run ejenix_cli:ejenix …`:

```sh
dart pub global activate --source path packages/cli
# add ~/.pub-cache/bin to PATH if it isn't already (the command prints how)
ejenix --version   # confirms the install; --help lists every command
```

Prefer not to install globally? Every command below also works as
`dart run ejenix_cli:ejenix <args>` from the repo root.

## 3. Build and verify your own patch

```sh
ejenix keygen -o app.key                       # an Ed25519 signing key

printf 'int add(int a, int b) => a + b;\nint main() => add(20, 22);\n' > patch.dart

# compile + sign
ejenix build patch.dart -o patch.bundle \
  --signing-key app.key --app-id com.example.app

ejenix verify patch.bundle --key app.key.pub   # verify offline
ejenix inspect patch.bundle                     # metadata + disassembly
```

`ejenix doctor` checks your environment; `ejenix init <dir>` scaffolds a project;
`ejenix build-delta` produces an update against a base bundle.

## 4. Run the Flutter example (a patchable app)

A real Flutter app whose home screen is an interpreted patch — change the patch,
and the screen changes with no rebuild.

```sh
cd example/patchable_app
./build.sh                                      # compile + sign the screen patch
flutter run --dart-define=PATCH_PUBKEY=$(cat keys/dev.key.pub)
```

Then see **live push**: with the app running, start the dev server and edit the
patch — the screen updates in ~10 ms without a rebuild.

```sh
# from the repo root, in a second terminal
ejenix watch example/patchable_app/patches/home_screen.dart \
  --signing-key example/patchable_app/keys/dev.key \
  --app-id com.example.patchable_app \
  --watch example/patchable_app/patch_sdk --host 0.0.0.0

# then re-run the app pointed at the dev server:
#   flutter run --dart-define=PATCH_PUBKEY=$(cat keys/dev.key.pub) \
#     --dart-define=PATCH_URL=http://<your-lan-ip>:8787
```

See [`example/patchable_app/README.md`](../example/patchable_app/README.md) for
how the app grants a patch its own widgets, state, and services.

## 5. Run the control plane

The self-hosted server that stores, promotes, and delta-encodes patches:

```sh
./deploy.sh --target docker        # local, needs Docker
# or: ./deploy.sh --target kubernetes | aws | gcp | azure | bare-metal
```

Configuration and cost estimates: [`deploy/README.md`](../deploy/README.md).

## Where to go next

- **Ship to real users:** [`docs/production.md`](production.md) — run your own
  control plane and push live updates with the `EjenixPatchView` SDK, including
  **channels** (one app, many patchable screens) and **staged rollout**
  (`--rollout 5` to expose a patch to a slice of the fleet first).
- **Before you ship to a public app store:**
  [Store review and interpreted code](production.md#store-review-and-interpreted-code)
  — the Apple and Google clauses that apply, and the one condition only you can
  satisfy.
- **Write patches:** [`spec/dart-subset.md`](../spec/dart-subset.md) — the exact
  Dart the compiler accepts.
- **Formats:** [`spec/bytecode.md`](../spec/bytecode.md),
  [`spec/bundle.md`](../spec/bundle.md), [`spec/host-api.md`](../spec/host-api.md).
- **Contribute:** [`CONTRIBUTING.md`](../CONTRIBUTING.md) — the quality gate every
  change must pass.
