# SSH access — arm-vm

```bash
./ssh/connect.sh
```

Connects to `ubuntu@80.225.254.55` using the key at `~/.ssh/oci-arm`.

Override the key path if needed:

```bash
SSH_KEY=/path/to/other/key ./ssh/connect.sh
```

Pass a command to run it remotely instead of opening a shell:

```bash
./ssh/connect.sh 'docker ps'
```
