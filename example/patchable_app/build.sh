#!/usr/bin/env bash
# Builds the patch: keygen (once) -> compile -> sign -> emit a bundle asset.
#
# This is the real toolchain, not a shortcut. The same `ejenix build` a team
# runs in CI produces the same signed bundle the device verifies. The only thing
# missing versus production is the fetch: `ejenix push` would upload this to
# the control plane, and `package:ejenix_loader` would download and stage it.
#
# Usage: example/patchable_app/build.sh   (from the repo root, or anywhere)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

APP_ID="com.example.patchable_app"
key="$here/keys/dev.key"
bundle="$here/assets/home_screen.bundle"

mkdir -p "$here/keys" "$here/assets"

# 0. This app resolves its own packages: it sits outside the root pub workspace,
#    so a `dart pub get` at the root never reaches it. The @Patchable codegen in
#    step 2 analyses lib/, and without Flutter's types resolved every parameter
#    reads as InvalidType — so resolve first rather than fail there.
if [ ! -f "$here/.dart_tool/package_config.json" ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "error: this example needs Flutter on PATH." >&2
    echo "       install: https://docs.flutter.dev/get-started/install" >&2
    exit 1
  fi
  echo "==> resolving the example app's packages"
  (cd "$here" && flutter pub get)
fi

# 1. A signing key. Real projects keep this in a secret manager and sign in CI;
#    a key checked into a repo is a key you must assume is compromised.
if [ ! -f "$key" ]; then
  echo "==> generating a dev signing key"
  dart run packages/cli/bin/ejenix.dart keygen -o "$key"
fi

# 2. Compile the patch and sign it. The patch imports ../patch_sdk/flutter.dart
#    and ../patch_sdk/app.dart, so the analyzer resolves the typed surface — in
#    the compiler *and* in the author's editor — and the compiler lowers each use
#    to a host call through the allow-list.
echo "==> syncing the framework half of the patch SDK from the bridge"
cp "$root/flutter_bridge/patch_sdk/flutter.dart" "$here/patch_sdk/flutter.dart"

# The app half of the SDK and the host bindings are generated from the
# @Patchable annotations on the app's real code, so the two never drift.
echo "==> generating patch_sdk/app.dart + app_capabilities.g.dart from @Patchable"
dart run packages/cli/bin/ejenix.dart gen \
  "$here/lib/design_system.dart" \
  "$here/lib/app_state.dart" \
  --out-sdk "$here/patch_sdk/app.dart" \
  --out-capabilities "$here/lib/app_capabilities.g.dart"

echo "==> compiling patches/home_screen.dart"
dart run packages/cli/bin/ejenix.dart compile \
  "$here/patches/home_screen.dart" \
  -o "$bundle" \
  --signing-key "$key" \
  --app-id "$APP_ID" \
  --flutter-version "3.44.6"

echo
echo "==> signed patch written to ${bundle#"$root"/}"
echo "    public key: $(cat "$key.pub")"
echo
echo "Run the app with the key it should trust:"
echo "  cd example/patchable_app"
echo "  flutter run --dart-define=PATCH_PUBKEY=\$(cat keys/dev.key.pub)"
