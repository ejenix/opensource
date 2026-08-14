# Docker deploy — self-hosted control plane

Runs the control plane (`packages/server`) as a single container: app registry,
signed-bundle upload, and environment promotion/rollback.
on-demand deltas.

## One command

```sh
./deploy/docker/up.sh
```

On first run this generates both secrets, records them in `deploy/docker/.env`
(gitignored, mode 0600), builds the image (multi-stage: AOT-compiled Dart binary
on a `scratch` runtime — a few MB), and starts the stack on
`http://localhost:8080`. Data persists in the `ejenix-data` volume.

The secrets go in `.env` rather than only in your shell for two reasons:
Compose reads it automatically, so `docker compose down`, `logs`, and `restart`
work from any terminal; and it keeps `EJENIX_DELIVERY_SEED` stable across
restarts, which is the point of the seed. Re-running `up.sh` reuses what is
already there — it does not rotate your keys behind your back.

Verify it:

```sh
curl http://localhost:8080/v1/health      # {"status":"ok"}
```

Tear it down:

```sh
cd deploy/docker && docker compose down    # add -v to wipe the data volume
```

## Configuration (12-factor)

| Variable               | Required | Default     | Purpose                              |
| ---------------------- | -------- | ----------- | ------------------------------------ |
| `EJENIX_ADMIN_KEY`     | yes      | generated   | Bearer token for app administration  |
| `EJENIX_PORT`          | no       | `8080`      | Listen port                          |
| `EJENIX_DATA_DIR`      | no       | `/data`     | Persistent store (mapped to a volume)|
| `EJENIX_DELIVERY_SEED` | no       | generated   | 32-byte hex seed for the delta key   |

`up.sh` generates either one if it is missing. Set `EJENIX_DELIVERY_SEED`
yourself in production so the delivery public key is stable across restarts —
devices trust it to verify server-signed deltas, and a new seed means every
client must be re-pointed.

An **empty** value counts as unset: the server generates an ephemeral key and
says so at startup, rather than treating `""` as a seed. Container platforms
routinely pass unset variables through as empty strings, and the alternative is
a crash loop with `ed25519: bad seed length 0`.

## Endpoints

`POST /v1/apps`, `POST /v1/apps/<app>/bundles`, `POST
/v1/apps/<app>/envs/<env>/active`, `GET /v1/apps/<app>/log`, `GET /v1/health`,
`GET /v1/ready`, `GET /metrics`. See `packages/server` for the full surface.

## Cost estimate

The control plane is a single stateless-except-for-storage Dart binary. Sizing:

- **Compute:** comfortably fits **1 vCPU / 512 MB RAM**. On a small cloud VM
  (e.g. a 1 vCPU / 1 GB instance) that is roughly **US$5–7 / month**, and it is
  within the always-free tier of several providers.
- **Storage:** bundles are small (hundreds of bytes to a few KB); a
  **1–5 GB** volume (≈ **US$0.10–0.50 / month**) is ample
  for most apps.
- **Egress:** dominated by device bundle/delta downloads; deltas keep this to
  KBs per update. Typically **< US$1 / month** at small scale.

**Rough total: under US$10 / month** for a self-hosted single-node deployment.
Scale horizontally behind a load balancer with a shared `EJENIX_DATA_DIR`
(network volume) for higher throughput.

> Note: this template is provided ready-to-run. A full cloud execution (AWS/GCP/
> Azure/Kubernetes/bare-metal) requires your own account and credentials and is
> a user-gated step in the project's Definition of Done.
