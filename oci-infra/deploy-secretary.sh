#!/usr/bin/env bash
# Deploys/redeploys the FoyerIQ secretary/society console (../foyeriq-secretary)
# to arm-vm, on its own domain (SECRETARY_DOMAIN, default community.foyeriq.in)
# with its own Let's Encrypt cert, reusing the same 443 SNI dispatch as
# Postgres/pgAdmin4/Redis Insight/the site/the API/the admin console.
#
#   client --TLS--> nginx:443 (stream, ssl_preread SNI dispatch; see setup-postgres.sh)
#                      '-- SNI = $SECRETARY_DOMAIN --TLS-terminated--> 127.0.0.1:18447 (nginx http vhost)
#                             -> 127.0.0.1:8082 (secretary container, docker bridge network)
#
# Like foyeriq-admin, foyeriq-secretary is a pure static SPA (Vite build, no
# server-side runtime, no DB/Redis access) — served here by an nginx:alpine
# container on an ordinary docker bridge network (no --network host needed),
# with only 127.0.0.1:$SECRETARY_PORT published. It needs no secrets/.env of
# its own.
#
# Its only configuration is a handful of VITE_-prefixed values, which Vite
# bakes into the static JS bundle at *build* time (not read at runtime) — so
# they're passed as Docker build-args here:
#   - VITE_API_BASE_URL points at $API_DOMAIN (deploy-api.sh)
#   - VITE_OTP_BYPASS_ENABLED / VITE_OTP_DEV_BYPASS_CODE mirror the API's own
#     OTP_BYPASS_ENABLED / OTP_DEV_BYPASS_CODE (deploy-api.sh) so the login
#     screen's "use bypass code" hint matches what the API actually accepts.
#     Flip both back once real SMS/email/WhatsApp providers are wired up.
#
# The secretary app calls the API cross-origin
# (community.foyeriq.in -> api.foyeriq.in), so deploy-api.sh's CORS_ORIGINS
# must include https://$SECRETARY_DOMAIN — it already does by default.
#
# Usage:
#   export BW_SESSION=$(bw unlock --raw)
#   ./oci-infra/deploy-secretary.sh
#
# Requires a clean, pushed foyeriq-secretary checkout (deploys `git archive
# HEAD`, so uncommitted changes are NOT deployed), the Bitwarden CLI unlocked
# for this shell, and SECRETARY_DOMAIN (default community.foyeriq.in) already
# resolving to this VM's IP through Cloudflare (needed for the certbot HTTP-01
# challenge below). VM_IP/VM_USER come from .env at the repo root (see
# .env.example).
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
SECRETARY_DIR="${SECRETARY_DIR:-$REPO_ROOT/../foyeriq-secretary}"
SECRETARY_REMOTE_DIR="${SECRETARY_REMOTE_DIR:-/opt/foyeriq-secretary}"
SECRETARY_DOMAIN="${SECRETARY_DOMAIN:-community.foyeriq.in}"
SECRETARY_PORT="${SECRETARY_PORT:-8082}"
SECRETARY_VHOST_PORT="${SECRETARY_VHOST_PORT:-18447}"
API_DOMAIN="${API_DOMAIN:-api.foyeriq.in}"
# Mirrors deploy-api.sh's own OTP_BYPASS_ENABLED default — see header comment.
OTP_BYPASS_ENABLED="${OTP_BYPASS_ENABLED:-true}"
OTP_DEV_BYPASS_CODE="${OTP_DEV_BYPASS_CODE:-123456}"

[[ -d "$SECRETARY_DIR/.git" ]] || { echo "SECRETARY_DIR ($SECRETARY_DIR) is not a git checkout of foyeriq-secretary." >&2; exit 1; }
if [[ -n "$(git -C "$SECRETARY_DIR" status --porcelain)" ]]; then
  echo "$SECRETARY_DIR has uncommitted changes — this script deploys 'git archive HEAD', so commit/stash first." >&2
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

echo "==> Requesting/expanding Let's Encrypt cert for $SECRETARY_DOMAIN (HTTP-01, webroot)"
echo "    Requires $SECRETARY_DOMAIN to already resolve to this VM through Cloudflare."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d $SECRETARY_DOMAIN \
  --agree-tos -m $CERTBOT_EMAIL --non-interactive --expand --keep-until-expiring"

echo "==> Shipping secretary source (git archive HEAD -> $SECRETARY_REMOTE_DIR/app)"
ssh_run "sudo mkdir -p $SECRETARY_REMOTE_DIR/app && sudo chown -R \$USER:\$USER $SECRETARY_REMOTE_DIR"
git -C "$SECRETARY_DIR" archive --format=tar HEAD | ssh_run "rm -rf $SECRETARY_REMOTE_DIR/app/* && tar -x -C $SECRETARY_REMOTE_DIR/app"
echo "    ok ($(git -C "$SECRETARY_DIR" rev-parse --short HEAD))"

echo "==> Building Docker image (VITE_API_BASE_URL=https://$API_DOMAIN/api/v1, VITE_OTP_BYPASS_ENABLED=$OTP_BYPASS_ENABLED baked in at build time)"
ssh_run "cd $SECRETARY_REMOTE_DIR/app && sudo docker build \
  --build-arg VITE_API_BASE_URL=https://$API_DOMAIN/api/v1 \
  --build-arg VITE_OTP_BYPASS_ENABLED=$OTP_BYPASS_ENABLED \
  --build-arg VITE_OTP_DEV_BYPASS_CODE=$OTP_DEV_BYPASS_CODE \
  -t foyeriq-secretary:latest ."

echo "==> Starting secretary container (docker, bridge network, bound to 127.0.0.1:$SECRETARY_PORT only)"
ssh_run "
  sudo docker rm -f foyeriq-secretary >/dev/null 2>&1 || true
  sudo docker run -d --name foyeriq-secretary --restart unless-stopped \
    -p 127.0.0.1:$SECRETARY_PORT:80 \
    foyeriq-secretary:latest >/dev/null
"
echo "    ok"

echo "==> Configuring nginx: internal HTTPS vhost for secretary (127.0.0.1:$SECRETARY_VHOST_PORT -> docker:$SECRETARY_PORT)"
ssh_run "sudo tee /etc/nginx/conf.d/foyeriq-secretary.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:$SECRETARY_VHOST_PORT ssl;
    server_name $SECRETARY_DOMAIN;
    client_max_body_size 10m;
    ssl_certificate     /etc/letsencrypt/live/$SECRETARY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SECRETARY_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$SECRETARY_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
}
CONF"

echo "==> Routing \$SECRETARY_DOMAIN's SNI on public 443 to the secretary vhost"
ssh_run "sudo mkdir -p /etc/nginx/stream.d/sni.d"
echo "$SECRETARY_DOMAIN     127.0.0.1:$SECRETARY_VHOST_PORT;" | ssh_run "sudo tee /etc/nginx/stream.d/sni.d/foyeriq-secretary.conf >/dev/null"

# Written unconditionally so this always self-heals to the same include-form
# dispatch.conf that setup-postgres.sh, setup-redis.sh, deploy-site.sh,
# deploy-api.sh, and deploy-admin.sh also write byte-for-byte identically --
# see setup-redis.sh for the fuller explanation. Each script only manages its
# own snippet under stream.d/sni.d/*.conf, so whichever of these six runs
# last can't clobber the others' routes anymore.
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
ssh_run "curl -sf http://127.0.0.1:$SECRETARY_PORT/ >/dev/null && echo ok" || echo "    WARNING: local health check failed — check 'sudo docker logs foyeriq-secretary' on the VM."

echo
echo "==> Done. Verify: https://$SECRETARY_DOMAIN"
echo "    Logs:    ../ssh/connect.sh 'sudo docker logs -f foyeriq-secretary'"
echo "    Restart: ../ssh/connect.sh 'sudo docker restart foyeriq-secretary'"
