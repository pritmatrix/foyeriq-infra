#!/usr/bin/env bash
# Deploys/redeploys the FoyerIQ admin console (../foyeriq-admin) to arm-vm, on
# its own domain (ADMIN_DOMAIN, default admin.foyeriq.in) with its own Let's
# Encrypt cert, reusing the same 443 SNI dispatch as Postgres/pgAdmin4/Redis
# Insight/the site/the API.
#
#   client --TLS--> nginx:443 (stream, ssl_preread SNI dispatch; see setup-postgres.sh)
#                      '-- SNI = $ADMIN_DOMAIN --TLS-terminated--> 127.0.0.1:18446 (nginx http vhost)
#                             -> 127.0.0.1:8081 (admin container, docker bridge network)
#
# Unlike the site/API, foyeriq-admin is a pure static SPA (Vite build, no
# server-side runtime, no DB/Redis access) — served here by an nginx:alpine
# container. It doesn't need --network host at all, so it runs on an ordinary
# docker bridge network with only 127.0.0.1:$ADMIN_PORT published, and it
# needs no secrets/.env of its own.
#
# The only configuration the admin app has is VITE_API_BASE_URL, which Vite
# bakes into the static JS bundle at *build* time (not read at runtime like a
# server env var) — so it's passed as a Docker build-arg here, pointing at
# $API_DOMAIN (deploy-api.sh). If you change API_DOMAIN you must re-run this
# script to rebuild the bundle, not just restart the container.
#
# The admin app calls the API cross-origin (admin.foyeriq.in -> api.foyeriq.in),
# so deploy-api.sh's CORS_ORIGINS must include https://$ADMIN_DOMAIN — it
# already does by default.
#
# Usage:
#   export BW_SESSION=$(bw unlock --raw)
#   ./oci-infra/deploy-admin.sh
#
# Requires a clean, pushed foyeriq-admin checkout (deploys `git archive HEAD`,
# so uncommitted changes are NOT deployed), the Bitwarden CLI unlocked for
# this shell, and ADMIN_DOMAIN (default admin.foyeriq.in) already resolving to
# this VM's IP through Cloudflare (needed for the certbot HTTP-01 challenge
# below). VM_IP/VM_USER come from .env at the repo root (see .env.example).
#
# Safe to re-run (rebuilds the image, restarts the container, and skips the
# cert request if already issued).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/bw.sh"
load_env "$REPO_ROOT"

VM_USER="${VM_USER:-ubuntu}"
VM_IP="${VM_IP:-80.225.254.55}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"
BW_ITEM_POSTGRES="${BW_ITEM_POSTGRES:-arm-vm-postgres}"
ADMIN_DIR="${ADMIN_DIR:-$REPO_ROOT/../foyeriq-admin}"
ADMIN_REMOTE_DIR="${ADMIN_REMOTE_DIR:-/opt/foyeriq-admin}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.foyeriq.in}"
ADMIN_PORT="${ADMIN_PORT:-8081}"
ADMIN_VHOST_PORT="${ADMIN_VHOST_PORT:-18446}"
API_DOMAIN="${API_DOMAIN:-api.foyeriq.in}"

[[ -d "$ADMIN_DIR/.git" ]] || { echo "ADMIN_DIR ($ADMIN_DIR) is not a git checkout of foyeriq-admin." >&2; exit 1; }
if [[ -n "$(git -C "$ADMIN_DIR" status --porcelain)" ]]; then
  echo "$ADMIN_DIR has uncommitted changes — this script deploys 'git archive HEAD', so commit/stash first." >&2
  exit 1
fi

CLEANUP_FILES=()
cleanup() { for f in "${CLEANUP_FILES[@]:-}"; do [[ -f "$f" ]] && (shred -u "$f" 2>/dev/null || rm -f "$f"); done; }
trap cleanup EXIT

bw_require_session

echo "==> Fetching SSH keypair from Bitwarden (item: $BW_ITEM_SSH_KEY)"
SSH_KEY="$(mktemp)"
CLEANUP_FILES+=("$SSH_KEY")
bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
ssh_run() { ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"; }

echo "==> Ensuring Docker is installed"
ssh_run '
  set -e
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    sudo usermod -aG docker ubuntu
  else
    echo "    already installed: $(docker --version)"
  fi
'
# See deploy-site.sh for why this is re-applied unconditionally right after
# any Docker install step.
echo "==> Re-applying the Cloudflare origin lock on 80/443 (defends against Docker's iptables changes above)"
source "$REPO_ROOT/lib/firewall.sh"
apply_cloudflare_lock "$SCRIPT_DIR/cf-lock-iptables.sh"

CERTBOT_EMAIL="${CERTBOT_EMAIL:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_web_email)}"
[[ -n "$CERTBOT_EMAIL" ]] || { echo "Could not resolve a contact email for certbot from Bitwarden item $BW_ITEM_POSTGRES (pgadmin_web_email)." >&2; exit 1; }

echo "==> Requesting/expanding Let's Encrypt cert for $ADMIN_DOMAIN (HTTP-01, webroot)"
echo "    Requires $ADMIN_DOMAIN to already resolve to this VM through Cloudflare."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d $ADMIN_DOMAIN \
  --agree-tos -m $CERTBOT_EMAIL --non-interactive --expand --keep-until-expiring"

echo "==> Shipping admin source (git archive HEAD -> $ADMIN_REMOTE_DIR/app)"
ssh_run "sudo mkdir -p $ADMIN_REMOTE_DIR/app && sudo chown -R \$USER:\$USER $ADMIN_REMOTE_DIR"
git -C "$ADMIN_DIR" archive --format=tar HEAD | ssh_run "rm -rf $ADMIN_REMOTE_DIR/app/* && tar -x -C $ADMIN_REMOTE_DIR/app"
echo "    ok ($(git -C "$ADMIN_DIR" rev-parse --short HEAD))"

echo "==> Building Docker image (VITE_API_BASE_URL=https://$API_DOMAIN/api/v1 baked in at build time)"
ssh_run "cd $ADMIN_REMOTE_DIR/app && sudo docker build \
  --build-arg VITE_API_BASE_URL=https://$API_DOMAIN/api/v1 \
  -t foyeriq-admin:latest ."

echo "==> Starting admin container (docker, bridge network, bound to 127.0.0.1:$ADMIN_PORT only)"
ssh_run "
  sudo docker rm -f foyeriq-admin >/dev/null 2>&1 || true
  sudo docker run -d --name foyeriq-admin --restart unless-stopped \
    -p 127.0.0.1:$ADMIN_PORT:80 \
    foyeriq-admin:latest >/dev/null
"
echo "    ok"

echo "==> Configuring nginx: internal HTTPS vhost for admin (127.0.0.1:$ADMIN_VHOST_PORT -> docker:$ADMIN_PORT)"
ssh_run "sudo tee /etc/nginx/conf.d/foyeriq-admin.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:$ADMIN_VHOST_PORT ssl;
    server_name $ADMIN_DOMAIN;
    client_max_body_size 10m;
    ssl_certificate     /etc/letsencrypt/live/$ADMIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$ADMIN_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
}
CONF"

echo "==> Routing \$ADMIN_DOMAIN's SNI on public 443 to the admin vhost"
ssh_run "sudo mkdir -p /etc/nginx/stream.d/sni.d"
echo "$ADMIN_DOMAIN     127.0.0.1:$ADMIN_VHOST_PORT;" | ssh_run "sudo tee /etc/nginx/stream.d/sni.d/foyeriq-admin.conf >/dev/null"

# Written unconditionally so this always self-heals to the same include-form
# dispatch.conf that setup-postgres.sh, setup-redis.sh, deploy-site.sh, and
# deploy-api.sh also write byte-for-byte identically -- see setup-redis.sh for
# the fuller explanation. Each script only manages its own snippet under
# stream.d/sni.d/*.conf, so whichever of these five runs last can't clobber
# the others' routes anymore.
ssh_run '
  set -e
  grep -q "include /etc/nginx/stream.d/\*.conf;" /etc/nginx/nginx.conf || \
    sudo sed -i "/^http {/i stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n" /etc/nginx/nginx.conf
  sudo tee /etc/nginx/stream.d/dispatch.conf >/dev/null <<'"'"'CONF'"'"'
map $ssl_preread_server_name $backend {
    include /etc/nginx/stream.d/sni.d/*.conf;
    default 127.0.0.1:5432;
}
server {
    listen 443;
    ssl_preread on;
    proxy_pass $backend;
}
CONF
'

echo "==> Registering a certbot renewal hook to reload nginx (idempotent)"
ssh_run "
  sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
"

ssh_run 'sudo nginx -t && sudo systemctl reload nginx'
echo "    ok"

echo "==> Health check"
sleep 2
ssh_run "curl -sf http://127.0.0.1:$ADMIN_PORT/ >/dev/null && echo ok" || echo "    WARNING: local health check failed — check 'sudo docker logs foyeriq-admin' on the VM."

echo
echo "==> Done. Verify: https://$ADMIN_DOMAIN"
echo "    Logs:    ../ssh/connect.sh 'sudo docker logs -f foyeriq-admin'"
echo "    Restart: ../ssh/connect.sh 'sudo docker restart foyeriq-admin'"
