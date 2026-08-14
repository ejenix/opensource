#!/usr/bin/env bash
# End-to-end walkthrough: key -> compile+sign -> verify -> apply.
# Runs entirely on your machine; no server or device required.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ejenix() { (cd "$repo" && dart run ejenix_cli:ejenix "$@"); }

echo "==> Resolving example dependencies"
(cd "$here" && dart pub get >/dev/null)

echo "==> 1. Generate a signing key"
ejenix keygen -o "$work/app.key"

echo "==> 2. Compile + sign the patch into a bundle"
ejenix build "$here/patch.dart" -o "$work/hello.bundle" \
  --signing-key "$work/app.key" --app-id com.example.hello

echo "==> 3. Verify the bundle against the public key"
ejenix verify "$work/hello.bundle" --key "$work/app.key.pub"

echo "==> 4. Apply the patch on the (simulated) device"
(cd "$here" && dart run bin/apply.dart "$work/hello.bundle" "$work/app.key.pub")

echo
echo "Done. The patch compiled, was signed, verified, and executed to 226."
