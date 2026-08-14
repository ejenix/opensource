#!/usr/bin/env bash
# Ejenix control-plane deploy dispatcher.
#
# One entry point over the templates in `deploy/`. Every target executes: it
# builds the image, provisions what it needs, and deploys. The rule the cloud
# targets are built around is that a deploy script must never pretend to have
# done something it could not — so each one hard-preflights its CLI, its
# authentication, and its arguments before touching your account, and refuses
# to deploy a control plane that would silently lose its data.
#
# Pass --dry-run to a cloud target (aws/gcp/azure/bare-metal) to print the
# exact command sequence instead. docker and kubernetes reject it rather than
# ignoring it — see refuse_dry_run below.
#
#   ./deploy.sh --target docker
#   ./deploy.sh --target kubernetes
#   ./deploy.sh --target gcp --bucket my-ejenix-data
#   ./deploy.sh --target azure --resource-group ejenix-rg --storage-account ejenixdata
#   ./deploy.sh --target aws --ephemeral
#   sudo ./deploy.sh --target bare-metal
#
# Target-specific options: ./deploy.sh --target <t> --help
# See deploy/README.md for the full matrix and cost estimates.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
target=""
# Everything after the target is forwarded verbatim to the target script.
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="${2:-}"; shift 2 ;;
    --target=*) target="${1#*=}"; shift ;;
    -h | --help)
      # Before a target is named this is the dispatcher's own help; after one,
      # it belongs to the target.
      if [[ -z "$target" ]]; then target="help"; else passthrough+=("$1"); fi
      shift
      ;;
    *) passthrough+=("$1"); shift ;;
  esac
done

usage() {
  cat <<'EOF'
Ejenix — deploy the control plane

Usage: ./deploy.sh --target <TARGET>

Targets:
  docker        Build the image and start the stack locally
  kubernetes    Apply the manifest to the current kube-context
  gcp           Cloud Run + a mounted GCS bucket        (durable)
  azure         Container Apps + an Azure Files share   (durable)
  aws           App Runner from your ECR                (stateless; see below)
  bare-metal    AOT binary under systemd on this host   (durable)

Common options (all cloud targets):
  --dry-run     Print the exact command sequence; change nothing
  --tag <tag>   Image tag to build and deploy (default: 1.0.0)
  --ephemeral   Deploy with no persistent volume (data lost on restart)

Per-target options:  ./deploy.sh --target <target> --help

Every target runs the same image (deploy/docker/Dockerfile) and is configured by
EJENIX_ADMIN_KEY / EJENIX_DELIVERY_SEED / EJENIX_DATA_DIR / EJENIX_PORT. Unset
secrets are generated and printed once.

App Runner has no persistent-volume support, so the aws target requires
--ephemeral. For durable storage on AWS, run the same image on ECS/Fargate with
an EFS mount, or use bare-metal on EC2.

Full matrix and cost estimates: deploy/README.md
EOF
}

# --dry-run is honoured by the four cloud targets, which build their command
# sequence through the shared run() helper. docker and kubernetes exec straight
# into a tool that has no equivalent, so accepting the flag and ignoring it
# would do the one thing a dry run must never do: deploy. Refuse instead.
refuse_dry_run() {
  for arg in ${passthrough[@]+"${passthrough[@]}"}; do
    if [[ "$arg" == "--dry-run" ]]; then
      echo "--dry-run is not supported for --target $1." >&2
      echo "  Supported on: aws, gcp, azure, bare-metal." >&2
      echo "  To preview this target, read $2" >&2
      exit 64
    fi
  done
}

case "$target" in
  docker)
    refuse_dry_run docker "deploy/docker/up.sh and docker-compose.yml."
    exec "$here/deploy/docker/up.sh"
    ;;

  kubernetes | k8s)
    refuse_dry_run kubernetes "deploy/k8s/control-plane.yaml, or run
  kubectl apply --dry-run=client -f deploy/k8s/control-plane.yaml"
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "kubectl not found on PATH." >&2
      exit 69
    fi
    # The manifest reads EJENIX_ADMIN_KEY / EJENIX_DELIVERY_SEED from a Secret
    # named ejenix-secrets. Without it every pod sits in
    # CreateContainerConfigError, so create it here rather than leaving the
    # instructions in a comment inside the YAML.
    if ! kubectl get secret ejenix-secrets >/dev/null 2>&1; then
      admin="${EJENIX_ADMIN_KEY:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
      seed="${EJENIX_DELIVERY_SEED:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
      kubectl create secret generic ejenix-secrets \
        --from-literal=admin-key="$admin" \
        --from-literal=delivery-seed="$seed" >/dev/null
      cat >&2 <<BANNER
  ┌─ Generated secrets — save these now, they are not shown again ─────────────
  │  EJENIX_ADMIN_KEY=$admin
  │  EJENIX_DELIVERY_SEED=$seed
  └────────────────────────────────────────────────────────────────────────────
BANNER
    fi
    exec kubectl apply -f "$here/deploy/k8s/control-plane.yaml"
    ;;

  aws)
    exec "$here/deploy/cloud/aws.sh" "${passthrough[@]+"${passthrough[@]}"}"
    ;;

  gcp)
    exec "$here/deploy/cloud/gcp.sh" "${passthrough[@]+"${passthrough[@]}"}"
    ;;

  azure)
    exec "$here/deploy/cloud/azure.sh" "${passthrough[@]+"${passthrough[@]}"}"
    ;;

  bare-metal | baremetal | systemd)
    exec "$here/deploy/cloud/bare-metal.sh" "${passthrough[@]+"${passthrough[@]}"}"
    ;;

  "" | help | your-cloud)
    usage
    ;;

  *)
    echo "unknown target: '$target'" >&2
    echo
    usage
    exit 64
    ;;
esac
