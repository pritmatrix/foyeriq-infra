#!/usr/bin/env bash
# Lock the arm-vm's web ports (80/443) to Cloudflare's origin IP ranges only,
# and install a weekly systemd timer that refreshes them. Idempotent; run any
# time to (re)apply. The on-VM timer already handles Cloudflare range changes
# automatically — this standalone entry point is for the initial apply or a
# manual refresh without re-running the full setup.sh / setup-postgres.sh.
#
# Both foyeriq.in and pgadmin.foyeriq.in are Cloudflare-proxied, so all real
# web traffic comes from Cloudflare's edge; this stops anyone bypassing
# Cloudflare by hitting the origin IP directly. SSH (22) stays open. Direct
# Postgres-over-443 is intentionally no longer reachable — tunnel instead:
#   ./ssh/connect.sh -L 5432:127.0.0.1:5432
#   psql "host=127.0.0.1 port=5432 dbname=postgres user=<app_user> sslmode=require"
#
# The SSH key comes from Bitwarden (item $BW_ITEM_SSH_KEY) unless SSH_KEY= is
# set (see lib/bw.sh). VM_USER/VM_IP come from .env (see .env.example).
#
# Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/bw.sh"
source "$REPO_ROOT/lib/firewall.sh"
load_env "$REPO_ROOT"

VM_USER="${VM_USER:-ubuntu}"
VM_IP="${VM_IP:-80.225.254.55}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"

if [[ -n "${SSH_KEY:-}" ]]; then
  [[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY." >&2; exit 1; }
else
  bw_require_session
  echo "==> Fetching SSH key from Bitwarden (item: $BW_ITEM_SSH_KEY)"
  SSH_KEY="$(mktemp)"
  trap 'shred -u "$SSH_KEY" 2>/dev/null || rm -f "$SSH_KEY"' EXIT
  bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
fi

ssh_run() { ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"; }

apply_cloudflare_lock "$SCRIPT_DIR/cf-lock-iptables.sh"

echo
echo "==> Done. Inbound 80/443 now accept Cloudflare ranges only; SSH (22) stays open."
echo "    Postgres is no longer reachable on 443 directly — tunnel over SSH instead:"
echo "      ./ssh/connect.sh -L 5432:127.0.0.1:5432"
echo "      psql \"host=127.0.0.1 port=5432 dbname=postgres user=<app_user> sslmode=require\""
