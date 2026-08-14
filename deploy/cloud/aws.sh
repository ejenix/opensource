#!/usr/bin/env bash
# Deploy the control plane to AWS App Runner, from an image in your own ECR.
#
#   ./deploy.sh --target aws --ephemeral
#   ./deploy.sh --target aws --dry-run
#
# Why App Runner: it is the shortest real path from this repo to a running,
# TLS-terminated control plane on AWS. It is also stateless — App Runner has no
# persistent-volume support (EFS mounts are an ECS/Fargate feature, not an App
# Runner one). The control plane keeps uploaded bundles on disk, so this target
# requires --ephemeral to make that trade explicit. For durable AWS storage,
# run the container on ECS/Fargate with an EFS mount, or use the bare-metal
# target on EC2 — both keep the same image and the same environment contract.
set -euo pipefail

# shellcheck source=deploy/cloud/_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

AWS_REGION_ARG=""
CREATE_ROLES=0
ECR_REPO="ejenix-control-plane"
ACCESS_ROLE_NAME="AppRunnerECRAccessRole"

usage() {
  cat <<EOF
Deploy the Ejenix control plane to AWS App Runner.

Usage: ./deploy.sh --target aws [options]

Options:
  --region <region>    AWS region (default: your configured region)
  --repo <name>        ECR repository name (default: $ECR_REPO)
  --create-roles       Create the App Runner ECR access role if it is missing
$(common_usage_flags)

App Runner has no persistent volumes, so --ephemeral is required. For durable
storage use ECS/Fargate + EFS, or the bare-metal target on EC2.
EOF
}

while [[ $# -gt 0 ]]; do
  if common_arg "$@"; then
    shift "$CONSUMED"
    continue
  fi
  case "$1" in
    --region) AWS_REGION_ARG="${2:?--region needs a value}"; shift 2 ;;
    --region=*) AWS_REGION_ARG="${1#*=}"; shift ;;
    --repo) ECR_REPO="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*) ECR_REPO="${1#*=}"; shift ;;
    --create-roles) CREATE_ROLES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight --
step "Preflight"

need_cmd aws "Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
need_cmd docker "Install: https://docs.docker.com/get-docker/"

capture caller_identity aws sts get-caller-identity --output text --query Account
[[ -n "$caller_identity" ]] ||
  die "AWS credentials are not usable.
       Run 'aws configure' (or set AWS_PROFILE / AWS_ACCESS_KEY_ID) and retry."
ACCOUNT_ID="$caller_identity"
note "account:  $ACCOUNT_ID"

if [[ -n "$AWS_REGION_ARG" ]]; then
  REGION="$AWS_REGION_ARG"
else
  capture REGION aws configure get region
  [[ -n "$REGION" ]] ||
    die "no AWS region configured.
       Pass --region <region>, or run 'aws configure set region <region>'."
fi
export AWS_REGION="$REGION"
note "region:   $REGION"

docker info >/dev/null 2>&1 ||
  die "the Docker daemon is not running. Start Docker Desktop (or dockerd) and retry."

# App Runner cannot mount a volume, so there is no storage flag to offer here —
# the only honest options are --ephemeral or a different target.
require_persistence_decision "(App Runner supports no volume flag; use ECS/Fargate or bare-metal)" ""

REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
IMAGE="$REGISTRY/$ECR_REPO:$EJENIX_IMAGE_TAG"
note "image:    $IMAGE"

ensure_secrets
announce_dry_run

# --------------------------------------------------------------- ecr + push --
step "Ensuring the ECR repository exists"

capture existing_repo aws ecr describe-repositories \
  --repository-names "$ECR_REPO" --region "$REGION" --output text --query 'repositories[0].repositoryName'
if [[ "$existing_repo" == "$ECR_REPO" ]]; then
  note "$ECR_REPO already exists"
else
  run aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --output text --query 'repository.repositoryUri'
fi

step "Building and pushing the image"

# App Runner runs x86_64, so pin the platform: an arm64 image built on an Apple
# Silicon machine would push fine and then fail to start.
run docker build --platform linux/amd64 -f "$DOCKERFILE" -t "$IMAGE" "$ROOT"

if ((DRY_RUN)); then
  note "(dry run) aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY"
else
  aws ecr get-login-password --region "$REGION" |
    docker login --username AWS --password-stdin "$REGISTRY"
fi
run docker push "$IMAGE"

# ------------------------------------------------------------- access role --
step "Checking the App Runner ECR access role"

capture role_arn aws iam get-role --role-name "$ACCESS_ROLE_NAME" \
  --output text --query 'Role.Arn'

if [[ -z "$role_arn" ]]; then
  if ((CREATE_ROLES)); then
    trust="$(mktemp)"
    cat >"$trust" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "build.apprunner.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
    run aws iam create-role \
      --role-name "$ACCESS_ROLE_NAME" \
      --assume-role-policy-document "file://$trust" \
      --output text --query 'Role.Arn'
    run aws iam attach-role-policy \
      --role-name "$ACCESS_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess
    rm -f "$trust"
    role_arn="arn:aws:iam::$ACCOUNT_ID:role/$ACCESS_ROLE_NAME"
    # IAM is eventually consistent; App Runner rejects a role it cannot yet see.
    ((DRY_RUN)) || sleep 10
  elif ((DRY_RUN)); then
    role_arn="arn:aws:iam::$ACCOUNT_ID:role/$ACCESS_ROLE_NAME"
    note "(dry run) role $ACCESS_ROLE_NAME would be created with --create-roles"
  else
    die "IAM role '$ACCESS_ROLE_NAME' does not exist.

       App Runner needs it to pull from a private ECR repository. Re-run with
       --create-roles to have this script create it, or create it yourself:

         aws iam create-role --role-name $ACCESS_ROLE_NAME \\
           --assume-role-policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"build.apprunner.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}'
         aws iam attach-role-policy --role-name $ACCESS_ROLE_NAME \\
           --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
  fi
else
  note "using $role_arn"
fi

# ------------------------------------------------------------------ deploy --
step "Deploying the App Runner service"

# Runtime configuration. These land in the service configuration, which is
# readable by anyone with apprunner:DescribeService — see the note in
# deploy/cloud/README.md on promoting them to Secrets Manager.
src_config="$(mktemp)"
cat >"$src_config" <<EOF
{
  "AuthenticationConfiguration": { "AccessRoleArn": "$role_arn" },
  "AutoDeploymentsEnabled": false,
  "ImageRepository": {
    "ImageIdentifier": "$IMAGE",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "$EJENIX_PORT",
      "RuntimeEnvironmentVariables": {
        "EJENIX_PORT": "$EJENIX_PORT",
        "EJENIX_ADMIN_KEY": "$EJENIX_ADMIN_KEY",
        "EJENIX_DELIVERY_SEED": "$EJENIX_DELIVERY_SEED"
      }
    }
  }
}
EOF

capture service_arn aws apprunner list-services --region "$REGION" \
  --output text --query "ServiceSummaryList[?ServiceName=='$EJENIX_SERVICE_NAME'].ServiceArn | [0]"

if [[ -n "$service_arn" && "$service_arn" != "None" ]]; then
  note "service exists — updating to $EJENIX_IMAGE_TAG"
  run aws apprunner update-service \
    --region "$REGION" \
    --service-arn "$service_arn" \
    --source-configuration "file://$src_config" \
    --output text --query 'Service.Status'
else
  run aws apprunner create-service \
    --region "$REGION" \
    --service-name "$EJENIX_SERVICE_NAME" \
    --source-configuration "file://$src_config" \
    --instance-configuration '{"Cpu":"0.25 vCPU","Memory":"0.5 GB"}' \
    --health-check-configuration '{"Protocol":"HTTP","Path":"/v1/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}' \
    --output text --query 'Service.ServiceArn'
fi
rm -f "$src_config"

URL=""
if ! ((DRY_RUN)); then
  step "Waiting for the service to become RUNNING (this takes a few minutes)"
  for _ in $(seq 1 60); do
    capture service_arn aws apprunner list-services --region "$REGION" \
      --output text --query "ServiceSummaryList[?ServiceName=='$EJENIX_SERVICE_NAME'].ServiceArn | [0]"
    capture status aws apprunner describe-service --region "$REGION" \
      --service-arn "$service_arn" --output text --query 'Service.Status'
    case "$status" in
      RUNNING)
        capture domain aws apprunner describe-service --region "$REGION" \
          --service-arn "$service_arn" --output text --query 'Service.ServiceUrl'
        URL="https://$domain"
        break
        ;;
      CREATE_FAILED | DELETE_FAILED)
        die "App Runner reported status '$status'.
       Inspect it: aws apprunner describe-service --service-arn $service_arn"
        ;;
    esac
    note "status: ${status:-pending}"
    sleep 15
  done
  [[ -n "$URL" ]] || die "timed out waiting for the service to reach RUNNING."
fi

report_ready "$URL"
