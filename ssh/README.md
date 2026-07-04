# SSH access — arm-vm

```bash
./ssh/connect.sh
```

Connects to `ubuntu@80.225.254.55` (both the host and user come from `.env` at the repo root, or these defaults — see [oci-infra/README.md](../oci-infra/README.md#local-config-env)). The private key isn't a local file — it's fetched from the Bitwarden item `arm-vm-ssh-key` into a private temp file for the duration of the command, then shredded on exit. Requires the [Bitwarden CLI](https://bitwarden.com/help/cli/) logged in and unlocked for the current shell:

```bash
brew install bitwarden-cli
bw login          # once
export BW_SESSION=$(bw unlock --raw)   # once per shell/session
```

Override with a local key file instead (bypasses Bitwarden):

```bash
SSH_KEY=/path/to/other/key ./ssh/connect.sh
```

Pass a command to run it remotely instead of opening a shell:

```bash
./ssh/connect.sh 'docker ps'
```

## Load-gen service

`load-gen.sh` manages the keep-alive load-gen service on arm-vm — a `stress-ng` unit ([`load-gen.service`](load-gen.service)) that holds **~30% CPU + ~6 GB RAM** so Oracle doesn't reclaim the Always Free A1 instance as idle.

```bash
./ssh/load-gen.sh install                 # (re)install the service from load-gen.service, then start it
./ssh/load-gen.sh {status|start|stop|logs}
```

Uses the same `SSH_KEY` override as `connect.sh`.

**Why both CPU and memory:** Oracle only reclaims an instance if, over a 7-day window, its 95th-percentile **CPU, network, and memory are _all_ under 20%** — so sustained CPU alone is enough. The memory hold is an independent second guardian in case the CPU stressor dies (on the 23 GB box it lands ~28%). Network is deliberately not generated: hitting 20% of the vNIC would mean ~800 Mbps sustained and risks the 10 TB free egress cap, and the AND-logic means it's never needed. Rationale lives in the comments of [`load-gen.service`](load-gen.service).
