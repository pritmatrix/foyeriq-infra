#!/usr/bin/env bash
# Manages the keep-alive load-gen service on arm-vm (~30% CPU + ~6GB RAM),
# which stops Oracle reclaiming the Always Free A1 instance as idle. The unit
# it installs is ssh/load-gen.service — see there for the reclamation policy
# rationale (CPU alone suffices; the memory hold is a second guardian; network
# is deliberately not generated).
#
#   ./ssh/load-gen.sh install     # (re)install + start the service on the VM
#   ./ssh/load-gen.sh status|start|stop|logs
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
else
  bw_require_session
  SSH_KEY="$(mktemp)"
  trap 'shred -u "$SSH_KEY" 2>/dev/null || rm -f "$SSH_KEY"' EXIT
  bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
fi

ssh_run() { ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"; }

usage() { echo "Usage: $0 {install|status|start|stop|logs}" >&2; exit 1; }

case "${1:-}" in
  install)
    echo "==> Ensuring stress-ng is installed"
    ssh_run 'command -v stress-ng >/dev/null || { sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stress-ng; }'
    echo "==> Installing load-gen.service"
    ssh_run 'sudo tee /etc/systemd/system/load-gen.service >/dev/null' < "$SCRIPT_DIR/load-gen.service"
    ssh_run 'sudo systemctl daemon-reload && sudo systemctl enable --now load-gen && sudo systemctl restart load-gen && sudo systemctl --no-pager status load-gen | head -6'
    echo "==> Done."
    ;;
  status)
    ssh_run 'sudo systemctl status load-gen --no-pager; echo "== CPU (3s avg) =="; mpstat 1 3 2>/dev/null | tail -1; echo "== Memory (keep >20% of total to satisfy Oracle) =="; free -h | head -2'
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
