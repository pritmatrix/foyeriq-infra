#!/usr/bin/env bash
# Connects to the OCI Always Free A1 VM (arm-vm, ap-mumbai-1).
#
# The SSH private key lives in Bitwarden (item $BW_ITEM_SSH_KEY), not as a
# local file — fetched into a private temp file for the duration of this
# command and shredded on exit. Requires `export BW_SESSION=$(bw unlock
# --raw)` first (see lib/bw.sh). Set SSH_KEY=/path/to/key to bypass
# Bitwarden and use a local key file instead.
#
# VM_USER/VM_IP/BW_ITEM_SSH_KEY are configurable via .env at the repo root
# (see .env.example) — falls back to the defaults below if .env is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/bw.sh"
load_env "$REPO_ROOT"

VM_USER="${VM_USER:-ubuntu}"
VM_IP="${VM_IP:-80.225.254.55}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"

if [[ -n "${SSH_KEY:-}" ]]; then
  [[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY." >&2; exit 1; }
  exec ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"
fi

bw_require_session
TMP_KEY="$(mktemp)"
trap 'shred -u "$TMP_KEY" 2>/dev/null || rm -f "$TMP_KEY"' EXIT
bw_write_secret_file "$BW_ITEM_SSH_KEY" "$TMP_KEY"

exec ssh -i "$TMP_KEY" "$VM_USER@$VM_IP" "$@"
