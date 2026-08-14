# Cloud & bare-metal deploy

Four executable targets. Each one preflights its CLI, its authentication, and
its arguments before it touches your account, then builds, provisions, and
deploys. Pass `--dry-run` to any of them to print the exact command sequence
without changing anything.

```sh
./deploy.sh --target gcp        --bucket my-ejenix-data
./deploy.sh --target azure      --resource-group ejenix-rg --storage-account ejenixdata
./deploy.sh --target aws        --ephemeral
sudo ./deploy.sh --target bare-metal

./deploy.sh --target <t> --help    # per-target options
```

All three cloud targets run the same image (`deploy/docker/Dockerfile`);
bare-metal runs the same server AOT-compiled to a native binary.

## Secrets

`EJENIX_ADMIN_KEY` and `EJENIX_DELIVERY_SEED` are read from the environment. If
either is unset the script generates it and prints it **once** — save both.

The seed must stay stable across restarts: devices verify server-signed deltas
against the key derived from it. Lose it and every client has to be re-pointed
at the new delivery key.

Where the values end up differs by platform, and it is worth knowing which:

| Target      | Secret storage                                                  |
| ----------- | --------------------------------------------------------------- |
| Azure       | Container Apps secrets, referenced by `secretRef` — not in the env |
| AWS         | App Runner runtime environment variables (readable via `apprunner:DescribeService`) |
| GCP         | Cloud Run environment variables (readable via `run.services.get`) |
| Bare-metal  | `/etc/ejenix/secrets.env`, mode 0600, root-owned                 |

For AWS and GCP, promote them to Secrets Manager / Secret Manager once the
service is up — see "Hardening" below.

## Persistence

The control plane stores uploaded bundles and environment pointers in
`EJENIX_DATA_DIR` (default `/data`). A managed container service without a
mounted volume loses them on every restart and revision, so **every cloud
target refuses to deploy until you either mount storage or pass `--ephemeral`
to accept the loss deliberately.**

| Target      | Durable storage                            | Flag                |
| ----------- | ------------------------------------------ | ------------------- |
| GCP         | Cloud Storage bucket mounted at the data dir | `--bucket`          |
| Azure       | Azure Files share mounted at the data dir    | `--storage-account` |
| Bare-metal  | Local disk (`/var/lib/ejenix`)               | always durable      |
| AWS         | **Not available on App Runner** — see below  | `--ephemeral` only  |

## AWS

`--target aws` deploys to **App Runner**, building into your own ECR
repository. It is the shortest real path from this repo to a running,
TLS-terminated control plane on AWS.

App Runner has **no persistent-volume support** — EFS mounts are an ECS/Fargate
feature, not an App Runner one — so this target requires `--ephemeral`. That is
fine for evaluation and for a control plane you re-publish into from CI, but it
is not a durable production store.

For durable storage on AWS, either:

- run the same image on **ECS/Fargate** with an EFS volume mounted at `/data`
  and an ALB health check on `GET /v1/health`, or
- use the **bare-metal** target on an EC2 instance, which is durable by
  construction.

App Runner needs an IAM role to pull from private ECR. The script checks for
`AppRunnerECRAccessRole` and, with `--create-roles`, creates it.

**Cost:** App Runner at 0.25 vCPU / 0.5 GB ≈ **US$9–12/mo** at low, steady
traffic. ECS Fargate at the same size is comparable, plus a few cents for EFS
and the ALB.

## GCP

`--target gcp` deploys to **Cloud Run** (second-generation execution
environment) from Artifact Registry, and mounts the bucket you pass as
`--bucket` at the data directory — so this target is durable.

`--min-instances` defaults to `1` on purpose: scaling to zero cold-starts every
device check-in and discards the in-memory delivery key between requests.

**Cost:** Cloud Run at min-instances 1, low traffic ≈ **US$8–15/mo**, plus
pennies for bucket storage. A scale-to-zero config is cheaper but cold-starts.

## Azure

`--target azure` deploys to **Container Apps**. By default the image is built by
ACR Tasks (`az acr build`) rather than locally, so this target needs no Docker
daemon and always produces a `linux/amd64` image.

It is the most complete of the three managed targets: secrets are real platform
secrets referenced by `secretRef`, and `--storage-account` mounts an Azure Files
share at the data directory.

The script registers `Microsoft.App`, `Microsoft.OperationalInsights`,
`Microsoft.ContainerRegistry`, and `Microsoft.Storage` before it provisions
anything — a fresh subscription has none of them, and the omission surfaces
later as `(MissingSubscriptionRegistration)` from whichever command got there
first.

### When ACR Tasks is blocked

Azure disables Tasks on some subscriptions — pay-as-you-go accounts commonly
hit `(TasksOperationsNotAllowed) ACR Tasks requests for the registry … are not
permitted`. There is nothing to fix on the Azure side short of a support
request, so build locally and push instead:

```sh
./deploy.sh --target azure --resource-group ejenix-rg \
  --storage-account ejenixdata --local-build
```

That needs a running Docker daemon and produces the same `linux/amd64` image;
everything after the build is identical. The default path prints this
instruction if `az acr build` fails, so you do not have to know in advance.

**Cost:** 0.25 vCPU / 0.5 GB running steadily ≈ **US$10–15/mo**, plus Azure
Files at a few cents/GB.

## Bare-metal / VM (systemd)

`--target bare-metal` AOT-compiles the server to a single native executable,
installs it to `/opt/ejenix`, writes `/etc/ejenix/secrets.env` at mode 0600,
installs a hardened systemd unit, and starts it — then verifies the unit is
actually active rather than assuming.

The unit uses `DynamicUser=yes` with `StateDirectory=ejenix`, so the service
runs as a transient unprivileged user, systemd owns `/var/lib/ejenix`, and
nothing runs as root. It also sets `ProtectSystem=strict`, `PrivateTmp`,
`NoNewPrivileges`, and restricts address families and namespaces.

Needs root (or sudo) and a systemd host. On macOS use `--target docker`.

**Cost:** a 1 vCPU / 1 GB VM ≈ **US$5–7/mo**, or free on hardware you already
run. Front it with nginx or Caddy for TLS.

## Hardening

Once a service is up, these are the follow-ups worth doing:

- **AWS** — move the two values into Secrets Manager and reference them as
  `RuntimeEnvironmentSecrets`, which needs an App Runner *instance* role with
  `secretsmanager:GetSecretValue`.
- **GCP** — store them in Secret Manager and swap `--set-env-vars` for
  `--set-secrets`, granting the runtime service account `secretAccessor`.
- **All targets** — restrict ingress to the networks your CI and devices use;
  the control plane authenticates administration with the admin key, but it
  does not need to be reachable from the whole internet.
- **Back up `EJENIX_DATA_DIR`.** It holds the uploaded bundles and the
  environment pointers.

## Notes

- Health endpoints for load balancers: `GET /v1/health` (liveness),
  `GET /v1/ready` (readiness).
- Cost figures are order-of-magnitude at low, steady traffic (2026 list
  prices) — measure your own usage.
- Running any cloud target end-to-end needs your own account and credentials.
  The scripts execute, but nobody has run them against every provider's live
  API on your behalf; `--dry-run` first if you want to read the plan before it
  runs.
