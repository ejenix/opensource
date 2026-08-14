#!/usr/bin/env bash
# Shared preflight, configuration, and command plumbing for the cloud targets.
#
# Sourced by aws.sh / gcp.sh / azure.sh / bare-metal.sh. Nothing here deploys
# anything; it establishes the contract every target shares.
#
# The rule this file exists to enforce is the one the dispatcher was written
# around: a deploy script must never pretend to have done something it could
# not. So every target hard-preflights its CLI, its authentication, and its
# arguments *before* it mutates anything, `--dry-run` prints the exact command
# sequence instead of running it, and a target that cannot persist its data
# refuses to run until you say so out loud.

# Config shared by every target. Anything already exported wins, so CI can set
# these from a secret store and the script will not invent its own.
: "${EJENIX_PORT:=8080}"
: "${EJENIX_IMAGE_TAG:=1.0.0}"
: "${EJENIX_SERVICE_NAME:=ejenix-control-plane}"

DRY_RUN=0
EPHEMERAL=0

# Repo root, so a target can be run from anywhere.
_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$_common_dir/../.." && pwd)"
DOCKERFILE="$ROOT/deploy/docker/Dockerfile"

die() {
  echo "error: $*" >&2
  exit 1
}

note() { echo "  $*"; }

step() {
  echo
  echo "==> $*"
}

# need_cmd <command> <install hint>
need_cmd() {
  command -v "$1" >/dev/null 2>&1 ||
    die "'$1' not found on PATH.
       $2"
}

# redact <text> — replace any known secret VALUE with a placeholder.
#
# Redacting by value, not by flag name, is deliberate: secrets reach these
# commands buried inside composite arguments (GCP passes them inside a single
# --set-env-vars string), so matching on argument names would miss them. Any
# occurrence of the actual secret is masked wherever it appears.
redact() {
  local text="$1"
  local secret
  for secret in "${EJENIX_ADMIN_KEY:-}" "${EJENIX_DELIVERY_SEED:-}" \
    "${REGISTRY_PASSWORD:-}"; do
    [[ -n "$secret" ]] && text="${text//"$secret"/<redacted>}"
  done
  printf '%s' "$text"
}

# run <command...> — echo the command, then execute it unless --dry-run.
#
# Arguments are printed shell-quoted so a dry run is copy-pasteable, but every
# secret value is masked first. This used to print them verbatim, which put the
# admin key and the delivery seed into terminal scrollback and CI logs — and
# made --dry-run, the option an operator reaches for precisely because it feels
# safer, the one that disclosed the most.
run() {
  local rendered
  rendered="$(printf ' %q' "$@")"
  printf '   $%s\n' "$(redact "$rendered")"
  if ((DRY_RUN)); then
    return 0
  fi
  "$@"
}

# capture <var> <command...> — like run, but stores stdout in <var>. Under
# --dry-run the command still executes: capture is only ever used for reads
# (describe/list), never for anything that mutates the account.
capture() {
  local __var="$1"
  shift
  local __out
  __out="$("$@" 2>/dev/null || true)"
  printf -v "$__var" '%s' "$__out"
}

gen_hex32() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Generates the two secrets if the caller did not supply them, and prints them
# once. A generated EJENIX_DELIVERY_SEED that is not saved means devices stop
# trusting the delivery key after the next restart, so this is loud on purpose.
ensure_secrets() {
  local generated=0
  if [[ -z "${EJENIX_ADMIN_KEY:-}" ]]; then
    EJENIX_ADMIN_KEY="$(gen_hex32)"
    generated=1
  fi
  if [[ -z "${EJENIX_DELIVERY_SEED:-}" ]]; then
    EJENIX_DELIVERY_SEED="$(gen_hex32)"
    generated=1
  fi
  export EJENIX_ADMIN_KEY EJENIX_DELIVERY_SEED
  if ((generated)); then
    cat <<EOF

  ┌─ Generated secrets — save these now, they are not shown again ─────────────
  │ EJENIX_ADMIN_KEY=$EJENIX_ADMIN_KEY
  │ EJENIX_DELIVERY_SEED=$EJENIX_DELIVERY_SEED
  └────────────────────────────────────────────────────────────────────────────
  The seed must stay stable across restarts: devices verify server-signed
  deltas against the key derived from it. Lose it and every client must be
  re-pointed at the new delivery key.
EOF
  fi
}

# The control plane keeps uploaded bundles and environment pointers on disk.
# A managed container service without a mounted volume loses them on every
# revision and restart, so require the caller to opt into that explicitly.
require_persistence_decision() {
  local storage_flag="$1" storage_value="$2"
  if [[ -n "$storage_value" ]]; then
    return 0
  fi
  if ((EPHEMERAL)); then
    echo
    echo "  ! --ephemeral: no volume mounted at ${EJENIX_DATA_DIR:-/data}."
    echo "    Uploaded bundles and environment pointers are lost on restart."
    echo "    Fine for a trial; do not run production this way."
    return 0
  fi
  die "no persistent storage configured.

       The control plane stores uploaded bundles and environment pointers in
       ${EJENIX_DATA_DIR:-/data}. Without a volume they vanish on restart.

       Pass $storage_flag <value> to mount one, or --ephemeral to accept the
       data loss deliberately (trials and demos only)."
}

# Prints the common flags, for each target's --help.
common_usage_flags() {
  cat <<'EOF'
  --tag <tag>          Image tag to build and deploy (default: 1.0.0)
  --name <name>        Service name (default: ejenix-control-plane)
  --ephemeral          Deploy with no persistent volume (data lost on restart)
  --dry-run            Print the exact command sequence; change nothing
  -h, --help           Show this help
EOF
}

# Handles the flags every target shares. Returns 0 if it consumed the argument,
# 1 if the caller should handle it. Sets CONSUMED to how many args to shift.
common_arg() {
  CONSUMED=0
  case "$1" in
    --tag)
      EJENIX_IMAGE_TAG="${2:?--tag needs a value}"
      CONSUMED=2
      ;;
    --tag=*)
      EJENIX_IMAGE_TAG="${1#*=}"
      CONSUMED=1
      ;;
    --name)
      EJENIX_SERVICE_NAME="${2:?--name needs a value}"
      CONSUMED=2
      ;;
    --name=*)
      EJENIX_SERVICE_NAME="${1#*=}"
      CONSUMED=1
      ;;
    --ephemeral)
      EPHEMERAL=1
      CONSUMED=1
      ;;
    --dry-run)
      DRY_RUN=1
      CONSUMED=1
      ;;
    *) return 1 ;;
  esac
  return 0
}

announce_dry_run() {
  if ((DRY_RUN)); then
    echo
    echo "  --dry-run: printing the plan. Nothing below is executed."
  fi
}

# Final banner once a target has deployed. <url> may be empty if the platform
# did not report one yet.
report_ready() {
  local url="$1"
  echo
  if ((DRY_RUN)); then
    echo "Dry run complete — nothing was deployed."
    return 0
  fi
  echo "Control plane deployed."
  if [[ -n "$url" ]]; then
    echo "  URL:        $url"
    echo "  Health:     curl $url/v1/health"
    echo "  Dashboard:  $url/  (paste EJENIX_ADMIN_KEY)"
  fi
  echo
  echo "Register an app and its signing key:"
  echo "  dart run packages/cli/bin/ejenix.dart app create \\"
  echo "    --server ${url:-https://your-host} --token \$EJENIX_ADMIN_KEY \\"
  echo "    --app com.yourco.yourapp --public-key <release.key.pub>"
}
