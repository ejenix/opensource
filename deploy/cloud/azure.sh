#!/usr/bin/env bash
# Deploy the control plane to Azure Container Apps, from an image built in your
# own Azure Container Registry.
#
#   ./deploy.sh --target azure --resource-group ejenix-rg --storage-account ejenixdata
#   ./deploy.sh --target azure --resource-group ejenix-rg --dry-run
#
# By default this target builds the image with ACR Tasks (`az acr build`) rather
# than locally, so it needs no Docker daemon and always produces a linux/amd64
# image. Azure blocks Tasks on some subscriptions — pay-as-you-go accounts
# commonly see `TasksOperationsNotAllowed` — so `--local-build` builds with a
# local Docker daemon and pushes instead. Same image either way.
#
# Container Apps has real secret storage and can mount an Azure Files share, so
# this is the most complete of the three managed targets: the two secrets are
# referenced through `secretRef` rather than sitting in plaintext environment
# variables, and --storage-account makes the data directory durable.
set -euo pipefail

# shellcheck source=deploy/cloud/_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

RESOURCE_GROUP=""
LOCATION="eastus"
REGISTRY_NAME=""
STORAGE_ACCOUNT=""
SHARE_NAME="ejenix-data"
LOCAL_BUILD=0
ENV_NAME=""

usage() {
  cat <<EOF
Deploy the Ejenix control plane to Azure Container Apps.

Usage: ./deploy.sh --target azure --resource-group <name> [options]

Options:
  --resource-group <name>   Resource group (required; created if absent)
  --location <region>       Azure region (default: $LOCATION)
  --registry <name>         ACR name (default: derived from the service name)
  --storage-account <name>  Storage account for the Azure Files share, making
                            the data dir durable. Omit only with --ephemeral.
  --share <name>            File share name (default: $SHARE_NAME)
  --local-build             Build with local Docker and push, instead of ACR
                            Tasks. Use when Tasks is blocked on your subscription.
  --environment <name>      Container Apps environment (default: <service>-env)
$(common_usage_flags)
EOF
}

while [[ $# -gt 0 ]]; do
  if common_arg "$@"; then
    shift "$CONSUMED"
    continue
  fi
  case "$1" in
    --resource-group | -g) RESOURCE_GROUP="${2:?--resource-group needs a value}"; shift 2 ;;
    --resource-group=*) RESOURCE_GROUP="${1#*=}"; shift ;;
    --location) LOCATION="${2:?--location needs a value}"; shift 2 ;;
    --location=*) LOCATION="${1#*=}"; shift ;;
    --registry) REGISTRY_NAME="${2:?--registry needs a value}"; shift 2 ;;
    --registry=*) REGISTRY_NAME="${1#*=}"; shift ;;
    --storage-account) STORAGE_ACCOUNT="${2:?--storage-account needs a value}"; shift 2 ;;
    --storage-account=*) STORAGE_ACCOUNT="${1#*=}"; shift ;;
    --share) SHARE_NAME="${2:?--share needs a value}"; shift 2 ;;
    --share=*) SHARE_NAME="${1#*=}"; shift ;;
    --environment) ENV_NAME="${2:?--environment needs a value}"; shift 2 ;;
    --environment=*) ENV_NAME="${1#*=}"; shift ;;
    --local-build) LOCAL_BUILD=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight --
step "Preflight"

need_cmd az "Install: https://learn.microsoft.com/cli/azure/install-azure-cli"

[[ -n "$RESOURCE_GROUP" ]] ||
  die "--resource-group is required.
       Example: ./deploy.sh --target azure --resource-group ejenix-rg --storage-account ejenixdata"

capture subscription az account show --query id --output tsv
[[ -n "$subscription" ]] ||
  die "not signed in to Azure. Run 'az login' and retry."
note "subscription: $subscription"

# ACR names are globally unique and alphanumeric-only.
if [[ -z "$REGISTRY_NAME" ]]; then
  REGISTRY_NAME="$(printf '%s' "$EJENIX_SERVICE_NAME" | tr -cd '[:alnum:]')acr"
fi
[[ -z "$ENV_NAME" ]] && ENV_NAME="$EJENIX_SERVICE_NAME-env"

note "resource group: $RESOURCE_GROUP"
note "location:       $LOCATION"
note "registry:       $REGISTRY_NAME"

require_persistence_decision "--storage-account" "$STORAGE_ACCOUNT"

IMAGE_REF="$EJENIX_SERVICE_NAME:$EJENIX_IMAGE_TAG"
IMAGE="$REGISTRY_NAME.azurecr.io/$IMAGE_REF"
note "image:          $IMAGE"

ensure_secrets
announce_dry_run

# ------------------------------------------------------------- extensions ---
step "Ensuring the containerapp CLI extension and providers are present"

run az extension add --name containerapp --upgrade --only-show-errors

# Every namespace this script touches, not just the Container Apps ones. A fresh
# subscription has none of them registered, and the failure surfaces later as
# `(MissingSubscriptionRegistration) The subscription is not registered to use
# namespace '...'` from whichever command got there first.
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry Microsoft.Storage; do
  run az provider register --namespace "$ns" --wait
done

# -------------------------------------------------------------- resources ---
step "Ensuring the resource group exists"

capture rg_exists az group exists --name "$RESOURCE_GROUP"
if [[ "$rg_exists" == "true" ]]; then
  note "$RESOURCE_GROUP already exists"
else
  run az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi

step "Ensuring the container registry exists"

capture acr_exists az acr show --name "$REGISTRY_NAME" --query name --output tsv
if [[ -n "$acr_exists" ]]; then
  note "$REGISTRY_NAME already exists"
else
  run az acr create \
    --name "$REGISTRY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --sku Basic \
    --admin-enabled true \
    --location "$LOCATION" \
    --output none
fi

# ------------------------------------------------------------------ build ---
if ((LOCAL_BUILD)); then
  step "Building the image locally and pushing to ACR"

  need_cmd docker "Install: https://docs.docker.com/get-docker/
       (or drop --local-build to build in Azure with ACR Tasks)"
  docker info >/dev/null 2>&1 ||
    die "the Docker daemon is not running. Start Docker Desktop (or dockerd) and retry."

  # Container Apps runs x86_64, so pin the platform: an arm64 image built on an
  # Apple Silicon machine pushes fine and then fails to start.
  run docker build --platform linux/amd64 -f "$DOCKERFILE" -t "$IMAGE" "$ROOT"
  run az acr login --name "$REGISTRY_NAME"
  run docker push "$IMAGE"
else
  step "Building the image with ACR Tasks"

  # Builds in Azure, so no local Docker daemon and no architecture mismatch.
  # ACR Tasks is disabled on some subscriptions, so failing here is expected
  # rather than exceptional — say what to do instead of just surfacing the
  # Azure error.
  if ! run az acr build \
    --registry "$REGISTRY_NAME" \
    --image "$IMAGE_REF" \
    --file "$DOCKERFILE" \
    "$ROOT"; then
    die "ACR Tasks could not build the image.

       Azure blocks Tasks on some subscriptions (pay-as-you-go accounts often
       see 'TasksOperationsNotAllowed'). Build locally and push instead:

         ./deploy.sh --target azure --resource-group $RESOURCE_GROUP --local-build

       That needs a running Docker daemon, and produces the same image."
  fi
fi

# ---------------------------------------------------------------- storage ---
STORAGE_LINKED=""
if [[ -n "$STORAGE_ACCOUNT" ]]; then
  step "Ensuring the storage account and file share exist"

  capture sa_exists az storage account show \
    --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
    --query name --output tsv
  if [[ -n "$sa_exists" ]]; then
    note "$STORAGE_ACCOUNT already exists"
  else
    run az storage account create \
      --name "$STORAGE_ACCOUNT" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --output none
  fi

  capture sa_key az storage account keys list \
    --account-name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
    --query '[0].value' --output tsv

  if ((DRY_RUN)); then
    note "(dry run) az storage share-rm create --name $SHARE_NAME ..."
  else
    [[ -n "$sa_key" ]] || die "could not read a key for storage account '$STORAGE_ACCOUNT'."
    az storage share-rm create \
      --resource-group "$RESOURCE_GROUP" \
      --storage-account "$STORAGE_ACCOUNT" \
      --name "$SHARE_NAME" \
      --quota 100 \
      --output none 2>/dev/null || note "share $SHARE_NAME already exists"
  fi
  STORAGE_LINKED="ejenix-files"
fi

# ------------------------------------------------------------ environment ---
step "Ensuring the Container Apps environment exists"

capture env_exists az containerapp env show \
  --name "$ENV_NAME" --resource-group "$RESOURCE_GROUP" --query name --output tsv
if [[ -n "$env_exists" ]]; then
  note "$ENV_NAME already exists"
else
  run az containerapp env create \
    --name "$ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
fi

if [[ -n "$STORAGE_LINKED" ]]; then
  step "Linking the file share to the environment"
  if ((DRY_RUN)); then
    note "(dry run) az containerapp env storage set --storage-name $STORAGE_LINKED ..."
  else
    az containerapp env storage set \
      --name "$ENV_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --storage-name "$STORAGE_LINKED" \
      --azure-file-account-name "$STORAGE_ACCOUNT" \
      --azure-file-account-key "$sa_key" \
      --azure-file-share-name "$SHARE_NAME" \
      --access-mode ReadWrite \
      --output none
  fi
fi

# ------------------------------------------------------------------ deploy --
step "Deploying the container app"

capture env_id az containerapp env show \
  --name "$ENV_NAME" --resource-group "$RESOURCE_GROUP" --query id --output tsv
capture acr_user az acr credential show --name "$REGISTRY_NAME" --query username --output tsv
capture acr_pass az acr credential show --name "$REGISTRY_NAME" --query 'passwords[0].value' --output tsv

# Container Apps takes volume mounts only through a YAML spec, and the same
# spec carries the secrets — so the two values are stored as platform secrets
# and referenced, never inlined as plaintext env vars.
spec="$(mktemp)"
{
  cat <<EOF
location: $LOCATION
properties:
  managedEnvironmentId: ${env_id:-<environment-id>}
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: $EJENIX_PORT
      transport: auto
      allowInsecure: false
    registries:
      - server: $REGISTRY_NAME.azurecr.io
        username: ${acr_user:-<acr-user>}
        passwordSecretRef: registry-password
    secrets:
      - name: registry-password
        value: ${acr_pass:-<acr-password>}
      - name: admin-key
        value: $EJENIX_ADMIN_KEY
      - name: delivery-seed
        value: $EJENIX_DELIVERY_SEED
  template:
    containers:
      - name: control-plane
        image: $IMAGE
        resources:
          cpu: 0.25
          memory: 0.5Gi
        env:
          - name: EJENIX_PORT
            value: "$EJENIX_PORT"
          - name: EJENIX_DATA_DIR
            value: "${EJENIX_DATA_DIR:-/data}"
          - name: EJENIX_ADMIN_KEY
            secretRef: admin-key
          - name: EJENIX_DELIVERY_SEED
            secretRef: delivery-seed
        probes:
          - type: Liveness
            httpGet:
              path: /v1/health
              port: $EJENIX_PORT
            initialDelaySeconds: 5
            periodSeconds: 10
          - type: Readiness
            httpGet:
              path: /v1/ready
              port: $EJENIX_PORT
            initialDelaySeconds: 3
            periodSeconds: 10
EOF
  if [[ -n "$STORAGE_LINKED" ]]; then
    cat <<EOF
        volumeMounts:
          - volumeName: ejenix-data
            mountPath: ${EJENIX_DATA_DIR:-/data}
EOF
  fi
  cat <<EOF
    scale:
      minReplicas: 1
      maxReplicas: 1
EOF
  if [[ -n "$STORAGE_LINKED" ]]; then
    cat <<EOF
    volumes:
      - name: ejenix-data
        storageType: AzureFile
        storageName: $STORAGE_LINKED
EOF
  fi
} >"$spec"

if ((DRY_RUN)); then
  note "(dry run) container app spec that would be applied:"
  sed 's/^/     /' "$spec"
  note "(dry run) az containerapp create --name $EJENIX_SERVICE_NAME --resource-group $RESOURCE_GROUP --yaml <spec>"
else
  capture app_exists az containerapp show \
    --name "$EJENIX_SERVICE_NAME" --resource-group "$RESOURCE_GROUP" --query name --output tsv
  if [[ -n "$app_exists" ]]; then
    note "container app exists — updating"
    az containerapp update \
      --name "$EJENIX_SERVICE_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --yaml "$spec" \
      --output none
  else
    az containerapp create \
      --name "$EJENIX_SERVICE_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --yaml "$spec" \
      --output none
  fi
fi
rm -f "$spec"

URL=""
if ! ((DRY_RUN)); then
  capture fqdn az containerapp show \
    --name "$EJENIX_SERVICE_NAME" --resource-group "$RESOURCE_GROUP" \
    --query 'properties.configuration.ingress.fqdn' --output tsv
  [[ -n "$fqdn" ]] && URL="https://$fqdn"
fi

report_ready "$URL"
