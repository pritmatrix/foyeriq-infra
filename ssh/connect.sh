#!/usr/bin/env bash
# Connects to the OCI Always Free A1 VM (arm-vm, ap-mumbai-1).
set -euo pipefail

VM_USER="ubuntu"
VM_IP="80.225.254.55"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/oci-arm}"

[[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY. Set SSH_KEY=/path/to/key to override." >&2; exit 1; }

exec ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"
