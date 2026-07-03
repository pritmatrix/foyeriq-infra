# oci-infra

Post-provision setup for the arm-vm. Run against an already-existing VM (fresh boot, OS reinstall, or full re-setup) to reapply what was already configured on it, without re-deriving the steps.

```bash
./oci-infra/setup.sh
```

| File | Purpose |
|---|---|
| `setup.sh` | Idempotent, run from your machine. Discovers the VM's current public IP and ensures the cloud-level Security List allows 22/80/443, via the OCI API. Authorizes our public key, opens the guest iptables firewall for 80/443 (persisted), installs Docker + Compose, and provisions/attaches/mounts a 150GB Always Free block volume at `/mnt/data`. |
| `setup-postgres.sh` | Idempotent, run from your machine. Also discovers the VM's public IP and ensures 80/443 are open via the OCI API (can run standalone without `setup.sh` first). Installs the latest stable PostgreSQL (PGDG repo) and stands up **pgAdmin4**, exposing both over a single port — **443** — via nginx SNI dispatch. One Let's Encrypt cert covers both, auto-renewed via certbot's HTTP-01 challenge. Also applies a hardening pass (see below). |
| `cloud-init.yaml` | The equivalent first-boot config OCI applies automatically when the instance is first created. Kept for reference — `setup.sh` covers the same ground for VMs that already exist. |

Both scripts talk to the OCI API directly for IP discovery, Security List management, and (in `setup.sh`) block volume provisioning — this needs the [OCI CLI](https://docs.oracle.com/iaas/Content/API/Concepts/cliconcepts.htm) and `jq` installed locally:

```bash
brew install oci-cli jq
```

Everything else (installing packages, configuring services) happens over SSH to the VM.

## Secrets

There are no secrets in this repo or on disk — the SSH keypair, the OCI API signing key, and the Postgres/pgAdmin4 credentials all live in a Bitwarden vault, fetched at runtime into private temp files that get shredded when each script exits. Requires the [Bitwarden CLI](https://bitwarden.com/help/cli/) logged in and unlocked for the current shell:

```bash
brew install bitwarden-cli
bw login          # once
export BW_SESSION=$(bw unlock --raw)   # once per shell/session
```

`lib/bw.sh` (sourced by every script in this repo) documents and fetches from three vault items:

| Item | Contents |
|---|---|
| `arm-vm-ssh-key` | notes = SSH private key; field `public_key` |
| `arm-vm-oci-api-key` | notes = OCI API private key (PEM); fields `user_ocid`, `fingerprint`, `tenancy_ocid`, `region` |
| `arm-vm-postgres` | fields `domain`, `pgadmin_domain`, `pg_superuser`, `pg_superuser_password`, `app_user`, `app_user_password`, `pgadmin_web_email`, `pgadmin_web_password` |

Any of these can be bypassed per-field with the matching env var (`SSH_KEY=`, `OCI_CLI_USER=`/`OCI_CLI_FINGERPRINT=`/`OCI_CLI_TENANCY=`/`OCI_CLI_REGION=`/`OCI_CLI_KEY_FILE=`, `DOMAIN=`, `PG_SUPERUSER_PASSWORD=`, etc.) if Bitwarden is unavailable — the scripts only touch the vault for whatever wasn't already supplied that way.

## Local config (.env)

Everything else — non-secret resource identifiers and config that used to be hardcoded across scripts — lives in `.env` at the repo root (gitignored; copy `.env.example` to get started):

```bash
cp .env.example .env
```

| Var | Used by | Meaning |
|---|---|---|
| `VM_USER`, `VM_IP` | all scripts | SSH target. `VM_IP` here is only a fallback for `ssh/connect.sh` and `ssh/load-gen.sh` (no OCI API call) — the `oci-infra` scripts discover the current IP fresh via the API and ignore this unless you also export `VM_IP` yourself. |
| `INSTANCE_ID`, `AVAILABILITY_DOMAIN` | `setup.sh`, `setup-postgres.sh` | The arm-vm instance's OCID and AD. |
| `DATA_VOLUME_NAME`, `DATA_VOLUME_SIZE_GB`, `DATA_MOUNT_POINT` | `setup.sh` | Block volume settings (see Block storage below). |
| `BW_ITEM_SSH_KEY`, `BW_ITEM_OCI_KEY`, `BW_ITEM_POSTGRES` | all scripts | Bitwarden item names, in case you rename them in your vault. |

`lib/env.sh`'s `load_env` only fills in vars that aren't already set in the environment, so ad-hoc overrides (`VM_IP=1.2.3.4 ./ssh/connect.sh`) still take precedence over `.env`. Every var above has a hardcoded fallback matching the current values, so scripts keep working even with no `.env` present at all.

## Block storage

150GB Always Free-eligible block volume (`arm-vm-data`), Balanced performance (10 VPUs/GB — the free-tier performance level; higher tiers bill), mounted at `/mnt/data`. Combined with the 50GB boot volume, this maxes out OCI's 200GB Always Free block storage allowance in this tenancy.

`setup.sh` creates the volume and attachment via the OCI API (idempotent — looks up by display name first) if they don't already exist, then over SSH formats it ext4 on first run and adds a UUID-keyed `/etc/fstab` entry (`nofail`, so a detached/missing disk won't block boot). Re-running is a no-op if everything's already in place.

`setup-postgres.sh` relocates Postgres's data directory onto this volume (`/mnt/data/postgresql/<version>/main`) the first time it runs, so the database isn't constrained by the 50GB boot disk — stops Postgres, `rsync`s the data directory over, repoints `data_directory` in `postgresql.conf`, and renames the old location to `<path>.bak` (kept as a safety net, not deleted). Re-running is a no-op once the data directory is already under `/mnt/data`.

## Postgres + pgAdmin4, both on 443

```bash
./oci-infra/setup-postgres.sh
```

All config (domains, role names, passwords, pgAdmin login) comes from the `arm-vm-postgres` Bitwarden item — see [Secrets](#secrets) above. Override any field with the matching env var (`DOMAIN=`, `PG_SUPERUSER_PASSWORD=`, etc.) to bypass Bitwarden for that one value.

Requires:
- `DOMAIN` and `PGADMIN_DOMAIN` (from the vault, or overridden) to already have DNS A records pointing at the VM's IP.
- The cert is requested via certbot's automated HTTP-01 (webroot) challenge against the default nginx site on port 80 — no manual DNS TXT records, no DNS provider API. `certbot.timer` renews it unattended; deploy hooks reload nginx and refresh + restart Postgres so both pick up the renewed cert.

(The Security List — 80/443 only, nothing else — is ensured automatically via the OCI API at the start of the script; no manual OCI console step needed.)

**How both share 443:** nginx's stream module runs in `ssl_preread` mode on 443 — it peeks at the SNI of an incoming TLS ClientHello *without* terminating TLS, then forwards the raw encrypted bytes on untouched:
- SNI = `pgadmin.foyeriq.in` → an internal nginx vhost (`127.0.0.1:18443`) that actually terminates TLS and reverse-proxies to pgAdmin4 (docker, `127.0.0.1:5050`).
- Everything else (including Postgres's classic plaintext `SSLRequest` probe, which isn't valid TLS at all and so falls through `ssl_preread`) → straight to Postgres (`127.0.0.1:5432`), which terminates its own TLS using the same cert. Postgres only ever binds to localhost; 5432 is never opened externally, and `pg_hba.conf` requires `hostssl`.

This works with both classic `sslmode=require` clients and, on libpq 17+, `sslnegotiation=direct` (ALPN-based).

### Security hardening

443 is open to the entire internet, and because all traffic arrives at Postgres via the local nginx proxy, Postgres itself never sees real client IPs — a log-based fail2ban jail isn't viable here. The script compensates with:

- **Two separate Postgres roles.** `$PG_SUPERUSER` is a true superuser but has **no network `pg_hba` entry at all** — it can only log in locally (`sudo -u postgres psql` after SSHing in). `$APP_USER` is unprivileged (`CONNECT` + `USAGE`/`CREATE` on `public` only) and is the *only* role reachable over 443 — this is what external clients and pgAdmin4 should use.
- **Per-source-IP connection rate limiting** on 443 at the firewall (iptables `hashlimit`, 20/min with a burst of 30) — throttles brute-force/scanning attempts before they even reach nginx.
- **Timeouts**: `statement_timeout` and `idle_in_transaction_session_timeout` both set to 5 minutes, bounding the damage a stuck or malicious connection can do.
- **Connection logging**: `log_connections`/`log_disconnections` on.
- **TLS 1.2+ only** (both nginx and Postgres — `ssl_protocols`/`ssl_min_protocol_version`).
- **Unattended security upgrades** for OS packages and PGDG Postgres packages (reboots are not automatic).

Connect to Postgres from anywhere with the unprivileged app role:

```bash
psql "host=$DOMAIN port=443 dbname=postgres user=$APP_USER sslmode=require"
```

For true superuser/admin work, SSH in first — the superuser role can't be reached remotely:

```bash
./ssh/connect.sh
sudo -u postgres psql
```

pgAdmin4 web UI:

```
https://pgadmin.foyeriq.in   (login: $PGADMIN_WEB_EMAIL / $PGADMIN_WEB_PASSWORD)
```

Inside pgAdmin4, add a server pointing at `host=127.0.0.1 port=5432, user=$APP_USER` — it runs on the same VM as Postgres, so it reaches it directly rather than through the 443 proxy.

For day-to-day access (connecting, managing the load-gen service) see [ssh/README.md](../ssh/README.md).
