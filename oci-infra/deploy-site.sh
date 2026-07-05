#!/usr/bin/env bash
# Deploys/redeploys the FoyerIQ marketing site (../foyeriq-site) to arm-vm, on
# its own domain (SITE_DOMAIN, default foyeriq.in) — distinct from the
# "arm-vm-postgres" vault item's `domain` field (db.foyeriq.in), which is
# Postgres/pgAdmin's own domain and shares a *different* Let's Encrypt cert.
# Earlier versions of this script wrongly reused that Postgres domain/cert;
# it never actually got far enough to matter (migrations kept failing first),
# but SITE_DOMAIN now gets its own dedicated cert, requested here.
#
#   client --TLS--> nginx:443 (stream, ssl_preread SNI dispatch; see setup-postgres.sh)
#                      '-- SNI = $SITE_DOMAIN --TLS-terminated--> 127.0.0.1:18444 (nginx http vhost)
#                             -> 127.0.0.1:3000 (site container, docker --network host)
#
# Reuses the same 443 that Postgres/pgAdmin4 already share (setup-postgres.sh):
# this script adds one more line to the ssl_preread map (/etc/nginx/stream.d/dispatch.conf)
# routing $SITE_DOMAIN's SNI to a new internal HTTPS vhost instead of falling
# through to Postgres.
#
# The site container runs with --network host (like pgAdmin4) so it can reach
# Postgres on the VM's own 127.0.0.1:5432. The app can normally resolve its own
# DB/email secrets at *runtime* from Bitwarden Secrets Manager
# (src/instrumentation.ts, via the native @bitwarden/sdk-napi SDK) — but that
# SDK has no working prebuild on this VM (ARM64 + Alpine/musl base image), so
# it always fails there. This script fetches DB_USER/DB_PASSWORD itself
# instead, from the "arm-vm-postgres" Bitwarden *vault* item (the same one
# setup-postgres.sh uses) via the `bw` CLI, and injects them directly, with
# BWS_REQUIRED=false so the SDK's inevitable in-container failure is a startup
# warning rather than a fatal boot error. BREVO_API_KEY is left unset — blank
# is a supported "console-log instead of send" fallback in the app, matching
# the Turnstile/Maps decision, and no real Brevo key exists yet.
#
# Usage:
#   export BW_SESSION=$(bw unlock --raw)
#   ./oci-infra/deploy-site.sh
#
# Requires a clean, pushed foyeriq-site checkout (deploys `git archive HEAD`,
# so uncommitted changes are NOT deployed), the Bitwarden CLI unlocked for
# this shell, and SITE_DOMAIN (default foyeriq.in) already resolving to this
# VM's IP through Cloudflare (needed for the certbot HTTP-01 challenge below).
# VM_IP/VM_USER come from .env at the repo root (see .env.example).
#
# Safe to re-run (rebuilds the image, re-applies migrations, restarts the
# container, and skips the cert request if already issued).
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
SITE_DIR="${SITE_DIR:-$REPO_ROOT/../foyeriq-site}"
SITE_REMOTE_DIR="${SITE_REMOTE_DIR:-/opt/foyeriq-site}"
SITE_DOMAIN="${SITE_DOMAIN:-foyeriq.in}"
SITE_PORT="${SITE_PORT:-3000}"
SITE_VHOST_PORT="${SITE_VHOST_PORT:-18444}"

[[ -d "$SITE_DIR/.git" ]] || { echo "SITE_DIR ($SITE_DIR) is not a git checkout of foyeriq-site." >&2; exit 1; }
[[ -f "$SITE_DIR/.env" ]] || { echo "$SITE_DIR/.env not found — copy .env.example and fill in BWS_* first." >&2; exit 1; }
if [[ -n "$(git -C "$SITE_DIR" status --porcelain)" ]]; then
  echo "$SITE_DIR has uncommitted changes — this script deploys 'git archive HEAD', so commit/stash first." >&2
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
# Installing Docker can quietly disrupt the Cloudflare-origin-lock iptables
# rules (Docker manages its own chains and can reorder/reset others) — cheap
# to just re-apply the lock every run rather than risk a silent outage. This
# runs early/unconditionally, before anything below that could fail and abort
# the script, so a bad cert request or DB fetch never leaves this unapplied.
echo "==> Re-applying the Cloudflare origin lock on 80/443 (defends against Docker's iptables changes above)"
source "$REPO_ROOT/lib/firewall.sh"
apply_cloudflare_lock "$SCRIPT_DIR/cf-lock-iptables.sh"

echo "==> Fetching DB credentials from Bitwarden vault item: $BW_ITEM_POSTGRES"
DB_USER="${DB_USER:-$(bw_field "$BW_ITEM_POSTGRES" app_user)}"
DB_PASSWORD="${DB_PASSWORD:-$(bw_field "$BW_ITEM_POSTGRES" app_user_password)}"
[[ -n "$DB_USER" && -n "$DB_PASSWORD" ]] || { echo "Could not resolve app_user/app_user_password from Bitwarden item $BW_ITEM_POSTGRES." >&2; exit 1; }

CERTBOT_EMAIL="${CERTBOT_EMAIL:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_web_email)}"
[[ -n "$CERTBOT_EMAIL" ]] || { echo "Could not resolve a contact email for certbot from Bitwarden item $BW_ITEM_POSTGRES (pgadmin_web_email)." >&2; exit 1; }

echo "==> Requesting/expanding Let's Encrypt cert for $SITE_DOMAIN (HTTP-01, webroot)"
echo "    Requires $SITE_DOMAIN to already resolve to this VM through Cloudflare."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d $SITE_DOMAIN \
  --agree-tos -m $CERTBOT_EMAIL --non-interactive --expand --keep-until-expiring"

echo "==> Shipping site source (git archive HEAD -> $SITE_REMOTE_DIR/app)"
ssh_run "sudo mkdir -p $SITE_REMOTE_DIR/app && sudo chown -R \$USER:\$USER $SITE_REMOTE_DIR"
git -C "$SITE_DIR" archive --format=tar HEAD | ssh_run "rm -rf $SITE_REMOTE_DIR/app/* && tar -x -C $SITE_REMOTE_DIR/app"
echo "    ok ($(git -C "$SITE_DIR" rev-parse --short HEAD))"

echo "==> Writing production .env (DB creds from the Bitwarden vault, BWS bootstrap token from local .env)"
# DB_PASSWORD and the BWS_* bootstrap token are sensitive: DB_PASSWORD came from
# the Bitwarden vault fetch above, and BWS_* is read straight from your local,
# gitignored foyeriq-site/.env — neither is ever printed or hardcoded in this
# script. This temp file is chmod 600'd immediately and shredded on exit (see
# CLEANUP_FILES).
# TURNSTILE_*/GOOGLE_MAPS_KEY are left blank on purpose (feature-off) — the app
# already treats a blank key as "spam-check/maps disabled", per plan.
ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
CLEANUP_FILES+=("$ENV_FILE")
grep -E '^BWS_(ACCESS_TOKEN|ORG_ID|PROJECT_ID)=' "$SITE_DIR/.env" > "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
BWS_REQUIRED=false
SITE_URL=https://$SITE_DOMAIN
UPLOAD_DIR=./uploads
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=foyeriq_marketing
DB_SSL=true
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
EMAIL_FROM_ADDRESS=no-reply@$SITE_DOMAIN
EMAIL_FROM_NAME=FoyerIQ
CONTACT_EMAIL=contactus@$SITE_DOMAIN
SUPPORT_EMAIL=support@$SITE_DOMAIN
LEGAL_EMAIL=legal@$SITE_DOMAIN
SALES_EMAIL=sales@$SITE_DOMAIN
TURNSTILE_SITE_KEY=
TURNSTILE_SECRET_KEY=
GOOGLE_MAPS_KEY=
CALCOM_URL=
EOF
scp -i "$SSH_KEY" "$ENV_FILE" "$VM_USER@$VM_IP:$SITE_REMOTE_DIR/.env" >/dev/null
ssh_run "chmod 600 $SITE_REMOTE_DIR/.env"
echo "    ok"

echo "==> Building Docker images (runtime + builder, for migrations)"
ssh_run "cd $SITE_REMOTE_DIR/app && sudo docker build -t foyeriq-site:latest . && sudo docker build --target builder -t foyeriq-site:builder ."

echo "==> Running database migrations"
ssh_run "sudo docker run --rm --network host --env-file $SITE_REMOTE_DIR/.env foyeriq-site:builder npm run db:migrate"

echo "==> Starting site container (docker, host network, bound to 127.0.0.1:$SITE_PORT only)"
# HOSTNAME=0.0.0.0 is required: Next.js's standalone server.js binds to
# process.env.HOSTNAME if set, and --network host shares the VM's UTS
# namespace, so HOSTNAME would otherwise be inherited as "arm-vm" — which
# /etc/hosts on Debian/Ubuntu resolves to 127.0.1.1, NOT 127.0.0.1. The app
# would then listen on a different loopback address than nginx's proxy_pass
# targets, giving "Ready" in the container logs but 502 Bad Gateway from nginx.
ssh_run "
  sudo docker rm -f foyeriq-site >/dev/null 2>&1 || true
  sudo docker run -d --name foyeriq-site --restart unless-stopped \
    --network host \
    -e HOSTNAME=0.0.0.0 \
    --env-file $SITE_REMOTE_DIR/.env \
    foyeriq-site:latest >/dev/null
"
echo "    ok"

echo "==> Configuring nginx: internal HTTPS vhost for the site (127.0.0.1:$SITE_VHOST_PORT -> docker:$SITE_PORT)"
ssh_run "sudo tee /etc/nginx/conf.d/foyeriq-site.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:$SITE_VHOST_PORT ssl;
    server_name $SITE_DOMAIN;
    client_max_body_size 10m;
    ssl_certificate     /etc/letsencrypt/live/$SITE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SITE_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$SITE_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
}
CONF"

echo "==> Routing \$SITE_DOMAIN's SNI on public 443 to the site vhost (was falling through to Postgres)"
ssh_run "sudo mkdir -p /etc/nginx/stream.d/sni.d"
echo "$SITE_DOMAIN     127.0.0.1:$SITE_VHOST_PORT;" | ssh_run "sudo tee /etc/nginx/stream.d/sni.d/foyeriq-site.conf >/dev/null"

# Written unconditionally so this always self-heals to the same include-form
# dispatch.conf that setup-postgres.sh and setup-redis.sh also write
# byte-for-byte identically -- see setup-redis.sh for the fuller explanation.
# Each script only manages its own snippet under stream.d/sni.d/*.conf, so
# whichever of the three runs last can't clobber the others' routes anymore.
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
ssh_run "curl -sf http://127.0.0.1:$SITE_PORT/api/health && echo" || echo "    WARNING: local health check failed — check 'sudo docker logs foyeriq-site' on the VM."

echo
echo "==> Done. Verify: https://$SITE_DOMAIN"
echo "    Logs:    ../ssh/connect.sh 'sudo docker logs -f foyeriq-site'"
echo "    Restart: ../ssh/connect.sh 'sudo docker restart foyeriq-site'"
