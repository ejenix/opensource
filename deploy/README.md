# Deploy

The control plane is a single AOT-compiled Dart binary configured entirely by
environment variables (12-factor). Every target below runs the same container
image built from [`docker/Dockerfile`](docker/Dockerfile).

One entry point dispatches to all of them:

```sh
./deploy.sh --target docker                                     # runs locally
./deploy.sh --target kubernetes                                 # current kube-context
./deploy.sh --target gcp   --bucket my-ejenix-data              # Cloud Run
./deploy.sh --target azure --resource-group rg --storage-account sa
./deploy.sh --target aws   --ephemeral                          # App Runner
sudo ./deploy.sh --target bare-metal                            # systemd on this host
```

Every target executes. Each one preflights its CLI, its authentication, and its
arguments before touching anything, and on the cloud targets `--dry-run` prints the exact command
sequence without changing a thing — a deploy script should never pretend to have
done something it could not.

| Target      | Where                        | Storage                          |
| ----------- | ---------------------------- | -------------------------------- |
| Docker      | [`docker/`](docker/)         | named volume                     |
| Kubernetes  | [`k8s/`](k8s/)               | PVC in the manifest              |
| GCP         | [`cloud/`](cloud/README.md)  | GCS bucket (`--bucket`)          |
| Azure       | [`cloud/`](cloud/README.md)  | Azure Files (`--storage-account`)|
| AWS         | [`cloud/`](cloud/README.md)  | none — App Runner is stateless   |
| Bare-metal  | [`cloud/`](cloud/README.md)  | local disk                       |

The cloud targets refuse to deploy without persistent storage unless you pass
`--ephemeral`, because a control plane that silently loses its bundles on
restart is worse than one that did not start.

Required configuration for every target:

| Variable               | Required | Purpose                                   |
| ---------------------- | -------- | ----------------------------------------- |
| `EJENIX_ADMIN_KEY`     | yes      | Bearer token for app administration       |
| `EJENIX_DELIVERY_SEED` | prod     | Stable 32-byte hex seed for the delta key |
| `EJENIX_DATA_DIR`      | no       | Persistent store (default `/data`)        |
| `EJENIX_PORT`          | no       | Listen port (default `8080`)              |

Health endpoints for load balancers and orchestrators: `GET /v1/health`
(liveness), `GET /v1/ready` (readiness).

> Unset secrets are generated and printed once by every target. Save both:
> `EJENIX_DELIVERY_SEED` must stay stable across restarts or devices stop
> trusting the delivery key.

> The cloud targets execute against your own account and credentials. They have
> not been run against every provider's live API on your behalf — use
> `--dry-run` first if you want to read the plan before it runs.
