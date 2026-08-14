#!/usr/bin/env bash
# Deploy the control plane to Google Cloud Run, from an image in Artifact
# Registry.
#
#   ./deploy.sh --target gcp --bucket my-ejenix-data
#   ./deploy.sh --target gcp --dry-run
#
# Cloud Run (second-generation execution environment) can mount a Cloud Storage
# bucket as a filesystem, so unlike App Runner this target can be durable: pass
# --bucket and the control plane's data directory is backed by that bucket.
# Without one, pass --ephemeral and accept that bundles vanish on restart.
#
# min-instances is 1 by default: scaling to zero would cold-start every device
# check-in and discard the in-memory delivery key between requests.
set -euo pipefail

# shellcheck source=deploy/cloud/_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

PROJECT_ARG=""
REGION_ARG=""
BUCKET=""
AR_REPO="ejenix"
MIN_INSTANCES=1

usage() {
  cat <<EOF
Deploy the Ejenix control plane to Google Cloud Run.

Usage: ./deploy.sh --target gcp [options]

Options:
  --project <id>       GCP project (default: your configured project)
  --region <region>    Cloud Run region (default: your configured region)
  --bucket <name>      Cloud Storage bucket to mount at the data dir (created
                       if absent). Omit only with --ephemeral.
  --repo <name>        Artifact Registry repository (default: $AR_REPO)
  --min-instances <n>  Minimum instances (default: $MIN_INSTANCES)
$(common_usage_flags)
EOF
}

while [[ $# -gt 0 ]]; do
  if common_arg "$@"; then
    shift "$CONSUMED"
    continue
  fi
  case "$1" in
    --project) PROJECT_ARG="${2:?--project needs a value}"; shift 2 ;;
    --project=*) PROJECT_ARG="${1#*=}"; shift ;;
    --region) REGION_ARG="${2:?--region needs a value}"; shift 2 ;;
    --region=*) REGION_ARG="${1#*=}"; shift ;;
    --bucket) BUCKET="${2:?--bucket needs a value}"; shift 2 ;;
    --bucket=*) BUCKET="${1#*=}"; shift ;;
    --repo) AR_REPO="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*) AR_REPO="${1#*=}"; shift ;;
    --min-instances) MIN_INSTANCES="${2:?--min-instances needs a value}"; shift 2 ;;
    --min-instances=*) MIN_INSTANCES="${1#*=}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight --
step "Preflight"

need_cmd gcloud "Install: https://cloud.google.com/sdk/docs/install"
need_cmd docker "Install: https://docs.docker.com/get-docker/"

capture active_account gcloud auth list --filter=status:ACTIVE --format='value(account)'
[[ -n "$active_account" ]] ||
  die "no active gcloud account. Run 'gcloud auth login' and retry."
note "account:  $active_account"

if [[ -n "$PROJECT_ARG" ]]; then
  PROJECT="$PROJECT_ARG"
else
  capture PROJECT gcloud config get-value project
  [[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] ||
    die "no GCP project configured.
       Pass --project <id>, or run 'gcloud config set project <id>'."
fi
note "project:  $PROJECT"

if [[ -n "$REGION_ARG" ]]; then
  REGION="$REGION_ARG"
else
  capture REGION gcloud config get-value run/region
  if [[ -z "$REGION" || "$REGION" == "(unset)" ]]; then
    capture REGION gcloud config get-value compute/region
  fi
  [[ -n "$REGION" && "$REGION" != "(unset)" ]] ||
    die "no region configured.
       Pass --region <region>, or run 'gcloud config set run/region <region>'."
fi
note "region:   $REGION"

docker info >/dev/null 2>&1 ||
  die "the Docker daemon is not running. Start Docker Desktop (or dockerd) and retry."

require_persistence_decision "--bucket" "$BUCKET"

IMAGE="$REGION-docker.pkg.dev/$PROJECT/$AR_REPO/$EJENIX_SERVICE_NAME:$EJENIX_IMAGE_TAG"
note "image:    $IMAGE"

ensure_secrets
announce_dry_run

# ------------------------------------------------------------------- apis ---
step "Enabling the required APIs (no-op if already enabled)"

run gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  --project "$PROJECT"

# ------------------------------------------------------- artifact registry --
step "Ensuring the Artifact Registry repository exists"

capture existing_repo gcloud artifacts repositories describe "$AR_REPO" \
  --location "$REGION" --project "$PROJECT" --format='value(name)'
if [[ -n "$existing_repo" ]]; then
  note "$AR_REPO already exists"
else
  run gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location "$REGION" \
    --project "$PROJECT" \
    --description "Ejenix control-plane images"
fi

# ----------------------------------------------------------------- bucket ---
if [[ -n "$BUCKET" ]]; then
  step "Ensuring the data bucket exists"
  capture existing_bucket gcloud storage buckets describe "gs://$BUCKET" \
    --project "$PROJECT" --format='value(name)'
  if [[ -n "$existing_bucket" ]]; then
    note "gs://$BUCKET already exists"
  else
    run gcloud storage buckets create "gs://$BUCKET" \
      --project "$PROJECT" \
      --location "$REGION" \
      --uniform-bucket-level-access
  fi
fi

# -------------------------------------------------------------- build/push --
step "Building and pushing the image"

# Cloud Run runs x86_64; pin the platform so an Apple Silicon build does not
# push successfully and then fail to start.
run gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
run docker build --platform linux/amd64 -f "$DOCKERFILE" -t "$IMAGE" "$ROOT"
run docker push "$IMAGE"

# ------------------------------------------------------------------ deploy --
step "Deploying to Cloud Run"

deploy_args=(
  run deploy "$EJENIX_SERVICE_NAME"
  --image "$IMAGE"
  --project "$PROJECT"
  --region "$REGION"
  --platform managed
  --port "$EJENIX_PORT"
  --cpu 1
  --memory 512Mi
  --min-instances "$MIN_INSTANCES"
  --execution-environment gen2
  --allow-unauthenticated
  --set-env-vars "EJENIX_PORT=$EJENIX_PORT,EJENIX_ADMIN_KEY=$EJENIX_ADMIN_KEY,EJENIX_DELIVERY_SEED=$EJENIX_DELIVERY_SEED,EJENIX_DATA_DIR=${EJENIX_DATA_DIR:-/data}"
)

# A Cloud Storage volume makes the data directory durable across revisions.
if [[ -n "$BUCKET" ]]; then
  deploy_args+=(
    --add-volume "name=ejenix-data,type=cloud-storage,bucket=$BUCKET"
    --add-volume-mount "volume=ejenix-data,mount-path=${EJENIX_DATA_DIR:-/data}"
  )
fi

run gcloud "${deploy_args[@]}"

URL=""
if ! ((DRY_RUN)); then
  capture URL gcloud run services describe "$EJENIX_SERVICE_NAME" \
    --project "$PROJECT" --region "$REGION" --format='value(status.url)'
fi

report_ready "$URL"
