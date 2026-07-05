# foyeriq-infra

Infrastructure-as-code for **arm-vm** — the FoyerIQ box running on Oracle Cloud's Always Free tier (an Ampere A1 instance, 4 OCPU / 24 GB, `ap-mumbai-1`). Everything here is idempotent and safe to re-run: the scripts reapply the VM's desired state (firewall, Docker, block storage, PostgreSQL + pgAdmin4) rather than documenting one-off manual steps.

No secrets live in this repo or on disk — the SSH key, OCI API signing key, and database credentials are all fetched from a Bitwarden vault at runtime. See [Secrets](#secrets).

## Repo map

| Path | What it's for |
|---|---|
| [`oci-infra/`](oci-infra/README.md) | Post-provision setup for the VM: base config ([`setup.sh`](oci-infra/setup.sh)), PostgreSQL + pgAdmin4 on 443 ([`setup-postgres.sh`](oci-infra/setup-postgres.sh)), Redis + Redis Insight ([`setup-redis.sh`](oci-infra/setup-redis.sh)), the marketing site ([`deploy-site.sh`](oci-infra/deploy-site.sh)), the API ([`deploy-api.sh`](oci-infra/deploy-api.sh)), and the Cloudflare origin lock ([`cloudflare-lock.sh`](oci-infra/cloudflare-lock.sh) / [`cf-lock-iptables.sh`](oci-infra/cf-lock-iptables.sh)). Start here for anything about the running server. |
| [`ssh/`](ssh/README.md) | Day-to-day access: [`connect.sh`](ssh/connect.sh) to get a shell (or run a remote command), and [`load-gen.sh`](ssh/load-gen.sh) to manage the keep-alive load service (~30% CPU + ~6 GB RAM, so Oracle doesn't reclaim the idle Always Free VM). |
| [`lib/`](lib/) | Shared bash helpers sourced by the scripts: [`bw.sh`](lib/bw.sh) (Bitwarden vault), [`env.sh`](lib/env.sh) (loads `.env`), [`firewall.sh`](lib/firewall.sh) (deploys the Cloudflare lock). Source these, don't run them. |
| [`share-oci-vm/`](share-oci-vm/README.md) | **Standalone, unrelated bundle** — a generic, shareable walk-through + provisioner for getting *your own* free OCI ARM VM from scratch. Not part of the arm-vm setup above; deliberately leaves 80/443 open to the world. |
| `.env` / [`.env.example`](.env.example) | Local, non-secret config (resource IDs, VM IP, Bitwarden item names). `.env` is gitignored; copy the example to get started. |

## Prerequisites

Install these on your PATH:

- **OCI CLI** + **jq** — for the Oracle Cloud API calls (IP discovery, Security List, block volume).
- **Bitwarden CLI** (`bw`) — for fetching secrets.

```bash
brew install oci-cli jq bitwarden-cli     # macOS
# Windows: winget install Oracle.OCI-CLI jqlang.jq Bitwarden.CLI
```

One-time auth:

```bash
oci setup config                 # or point OCI_CLI_* env vars at your key (setup.sh can pull them from Bitwarden)
bw login                         # once, ever
export BW_SESSION=$(bw unlock --raw)   # once per shell/session — tokens don't persist across shells
```

## Secrets

All secrets come from a Bitwarden vault, never from local files or plaintext env vars on the command line. [`lib/bw.sh`](lib/bw.sh) fetches them at runtime into private temp files that are shredded when each script exits. Vault items (names configurable via `.env`):

| Item | Contents |
|---|---|
| `arm-vm-ssh-key` | notes = SSH private key; field `public_key` |
| `arm-vm-oci-api-key` | notes = OCI API private key (PEM); fields `user_ocid`, `fingerprint`, `tenancy_ocid`, `region` |
| `arm-vm-postgres` | fields `domain`, `pgadmin_domain`, `pg_superuser(_password)`, `app_user(_password)`, `pgadmin_web_email/password` |
| `arm-vm-redis` | fields `redisinsight_domain`, `redis_password`, `redisinsight_web_user/password`, `letsencrypt_email` |
| `arm-vm-bws` (optional) | fields `access_token`, `project_id` — Bitwarden Secrets Manager bootstrap creds used by `deploy-api.sh` |

Any field can be bypassed with the matching env var (`SSH_KEY=`, `OCI_CLI_USER=`/`OCI_CLI_KEY_FILE=`/…, `DOMAIN=`, `PG_SUPERUSER_PASSWORD=`, …) if Bitwarden is unavailable — the scripts only touch the vault for whatever wasn't already supplied. Details in [oci-infra/README.md § Secrets](oci-infra/README.md#secrets).

## Local config (`.env`)

Non-secret identifiers and settings that used to be hardcoded across scripts live in `.env` at the repo root ([`lib/env.sh`](lib/env.sh) loads it; anything already set in your environment wins, so `VM_IP=1.2.3.4 ./ssh/connect.sh` still overrides). Every value has a built-in fallback, so scripts work even with no `.env` present.

```bash
cp .env.example .env      # then edit
```

## Common tasks

```bash
# SSH in (key pulled from Bitwarden)
./ssh/connect.sh
./ssh/connect.sh 'docker ps'                 # or run a one-off remote command

# Reapply base VM setup (firewall, Docker, 150GB data volume)
./oci-infra/setup.sh

# Install / reconfigure PostgreSQL + pgAdmin4 (both served on 443 via nginx SNI)
./oci-infra/setup-postgres.sh

# Deploy/redeploy the marketing site (foyeriq.in) — builds the Docker image on
# the VM from a clean ../foyeriq-site checkout, runs migrations, and adds it to
# the same 443 SNI dispatch as Postgres/pgAdmin4
./oci-infra/deploy-site.sh

# Install / reconfigure loopback-only Redis + Redis Insight
bash ./oci-infra/setup-redis.sh
# Windows PowerShell:
# & "C:\Program Files\Git\bin\bash.exe" ./oci-infra/setup-redis.sh

# Deploy/redeploy the API (api.foyeriq.in) — builds the Docker image on the VM
# from a clean ../foyeriq-apis checkout, runs migrations, fetches its secrets
# (JWT/MSG91/WhatsApp/Razorpay/ngrok) from Bitwarden Secrets Manager via the
# bws CLI, and adds it to the same 443 SNI dispatch as everything else
BWS_ACCESS_TOKEN=... ./oci-infra/deploy-api.sh   # BWS_ACCESS_TOKEN only needed once if not in the arm-vm-bws vault item

# (Re)apply just the Cloudflare origin lock on 80/443
./oci-infra/cloudflare-lock.sh

# Connect to Postgres — via an SSH tunnel, since 443 is Cloudflare-only (see below)
./ssh/connect.sh -L 5432:127.0.0.1:5432
psql "host=127.0.0.1 port=5432 dbname=postgres user=<app_user> sslmode=require"

# Keep-alive load service — ~30% CPU + ~6GB RAM (stops Oracle reclaiming an "idle" Always Free VM)
./ssh/load-gen.sh install                    # (re)install the service in the repo-tracked form
./ssh/load-gen.sh {status|start|stop|logs}
```

## The VM at a glance

- **Web ports (80/443) are locked to Cloudflare's origin ranges** at the guest `iptables` layer (the domains are Cloudflare-proxied) — the origin can't be reached by bypassing Cloudflare, and a weekly systemd timer refreshes the ranges. SSH (22) stays open. The OCI Security List (network edge) still allows 80/443 from anywhere; Cloudflare filtering happens one layer deeper. See [oci-infra/README.md § Security hardening](oci-infra/README.md#security-hardening).
- **PostgreSQL + pgAdmin4 both share port 443** via nginx `ssl_preread` SNI dispatch (`pgadmin.foyeriq.in` → pgAdmin4; everything else → Postgres). Postgres binds to localhost only; because 443 is now Cloudflare-only and Cloudflare doesn't proxy the Postgres wire protocol, reach the database through an **SSH tunnel** (see Common tasks).
- **150 GB Always Free block volume** at `/mnt/data` holds the Postgres data directory (keeps it off the 50 GB boot disk).
- **Docker + Compose**, unattended security upgrades, and Let's Encrypt certs (auto-renewed via certbot) are all set up by the `oci-infra` scripts.
