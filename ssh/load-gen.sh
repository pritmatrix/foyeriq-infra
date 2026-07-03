#!/usr/bin/env bash
# Manages the continuous ~30% CPU load-gen service on arm-vm.
# Keeps the Always Free A1 instance from looking idle to Oracle.
set -euo pipefail

VM_USER="ubuntu"
VM_IP="80.225.254.55"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/oci-arm}"

[[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY. Set SSH_KEY=/path/to/key to override." >&2; exit 1; }

ssh_run() { ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"; }

usage() { echo "Usage: $0 {status|start|stop|logs}" >&2; exit 1; }

case "${1:-}" in
  status)
    ssh_run 'sudo systemctl status load-gen --no-pager; echo; mpstat 1 3 2>/dev/null | tail -5'
    ;;
  start)
    ssh_run 'sudo systemctl start load-gen && sudo systemctl status load-gen --no-pager'
    ;;
  stop)
    ssh_run 'sudo systemctl stop load-gen && echo stopped'
    ;;
  logs)
    ssh_run 'sudo journalctl -u load-gen -n 50 --no-pager'
    ;;
  *)
    usage
    ;;
esac
