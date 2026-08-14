# hello_patch

A runnable, end-to-end example of the Ejenix over-the-air patch flow: compile a Dart patch, sign
it, verify it, and apply it through the sandboxed interpreter — no server or
device required.

This is the smallest complete picture of what Ejenix does; for the full Flutter
integration see [`example/patchable_app`](../patchable_app/README.md).

## Run it

```sh
./run.sh
```

You'll see the four stages and the final result:

```
✓ compiled 5 function(s) -> hello.bundle (751 bytes)
✓ bundle is valid
✓ signature and content integrity verified
  target app: com.example.hello
✓ applied patch → main() = 226
```

## What the patch shows

[`patch.dart`](patch.dart) stays inside the supported Dart subset while
exercising the interesting parts of it:

- a **class** (`Product`) with fields and a field-formal constructor;
- a **collection literal** of objects;
- a **closure** passed to `where` that **captures** a parameter;
- a **local function** (`discount`) that captures a local;
- integer arithmetic that the compiler **constant-folds** where it can.

## What `bin/apply.dart` shows

[`bin/apply.dart`](bin/apply.dart) is a ~40-line stand-in for the on-device
loader. It verifies the bundle's Ed25519 signature and content hash against the
trusted public key, decodes the module, and runs `main()` through the
interpreter. The real device lifecycle (fetch, stage, activate, crash-loop
rollback) lives in [`packages/loader`](../../packages/loader).

## Wiring into a Flutter app

In a Flutter app you would:

1. Ship the public key with the app and register your host capabilities on a
   `HostRegistry` (see `spec/host-api.md`).
2. On launch or resume, use `Loader.checkForUpdate(url)` to fetch, verify, and
   stage the newest bundle, then `activate` it.
3. Call the activated module's entry point from your widget/build logic and
   render its result.

Running the patch on **iOS, Android, and Web** devices requires a Flutter
toolchain and target devices, and is part of the project's device-CI Definition
of Done (a user-gated step). The compile → sign → verify → apply pipeline shown
here is identical on every platform.
