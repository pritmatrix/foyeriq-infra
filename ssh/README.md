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

`load-gen.sh` manages the continuous ~30% CPU load-gen service on arm-vm, which keeps the Always Free A1 instance from looking idle to Oracle.

```bash
./ssh/load-gen.sh {status|start|stop|logs}
```

Uses the same `SSH_KEY` override as `connect.sh`.
