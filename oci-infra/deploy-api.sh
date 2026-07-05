#!/usr/bin/env bash
# Deploys/redeploys the FoyerIQ API (../foyeriq-apis) to arm-vm, on its own
# domain (API_DOMAIN, default api.foyeriq.in) with its own Let's Encrypt cert,
# reusing the same 443 SNI dispatch as Postgres/pgAdmin4/Redis Insight/the site.
#
#   client --TLS--> nginx:443 (stream, ssl_preread SNI dispatch; see setup-postgres.sh)
#                      '-- SNI = $API_DOMAIN --TLS-terminated--> 127.0.0.1:18445 (nginx http vhost)
#                             -> 127.0.0.1:4000 (api container, docker --network host)
#
# The API container runs with --network host (like Postgres/pgAdmin4/the site)
# so it can reach Postgres on 127.0.0.1:5432 and Redis on 127.0.0.1:6379
# directly. PORT is overridden to 4000 (not the app's default 3000) because
# the site container already occupies 3000 on the host's shared network
# namespace.
#
# Like the site, the API normally resolves its own secrets at *runtime* from
# Bitwarden Secrets Manager (src/config/secrets, via the native
# @bitwarden/sdk-napi SDK) — but that SDK has no working prebuild on this VM
# (ARM64 + Alpine/musl), so it always fails there. This script instead:
#   - fetches DB_USER/DB_PASSWORD from the "arm-vm-postgres" Bitwarden *vault*
#     item (same one setup-postgres.sh / deploy-site.sh use) via `bw`
#   - fetches REDIS_PASSWORD from the "arm-vm-redis" vault item via `bw`
#   - fetches the rest of the API's secrets (JWT signing keys, MSG91,
#     WhatsApp, Razorpay, ngrok) from Bitwarden *Secrets Manager* via the
#     standalone `bws` CLI (which, unlike the Node SDK, does ship a Linux
#     ARM64 build) run once at deploy time on the VM — NOT from inside the
#     container. The container itself still gets BWS_REQUIRED=false so its
#     inevitable in-container SDK failure is just a startup warning.
#
# OTP_BYPASS_ENABLED=true (the default here) makes the API accept the fixed
# OTP_DEV_BYPASS_CODE for every login/signup even with NODE_ENV=production —
# real MSG91/Brevo/WhatsApp accounts aren't set up yet, so this is the only
# way to actually log in right now. It only affects OTP acceptance (see
# foyeriq-apis/src/modules/auth/auth.service.ts); it does NOT relax anything
# else NODE_ENV=production controls (error detail exposure, SQL/request
# logging, etc — those stay production-strict). Redeploy with
# OTP_BYPASS_ENABLED=false once a real provider is wired up.
#
# BWS_ACCESS_TOKEN is a non-secret-in-this-script bootstrap credential for
# that fetch — supply it as an env var (pulled from your own local
# ../foyeriq-apis/.env, which already has it) the first time you run this
# script, e.g.:
#   BWS_ACCESS_TOKEN=... ./oci-infra/deploy-api.sh
# BWS_PROJECT_ID defaults to "FoyerIQ-OCI"
# (22915112-f062-4fe9-ad35-b47d0042f922) — the Secrets Manager project
# purpose-built for this deployment (sibling to "FoyerIQ-Local",
# de42ca35-44fd-4cf9-9506-b4680042b0dc, used for local dev). It holds every
# secret this script needs except NGROK_AUTHTOKEN, which is dev-only and
# fine to skip here. If you'd rather not pass the token on the command line
# every time, add a Bitwarden *vault* item named "arm-vm-bws" with custom
# fields access_token/project_id — this script tries that first and only
# falls back to the env vars above.
#
# Usage:
#   export BW_SESSION=$(bw unlock --raw)
#   BWS_ACCESS_TOKEN=... ./oci-infra/deploy-api.sh
#
# Requires a clean, pushed foyeriq-apis checkout (deploys `git archive HEAD`,
# so uncommitted changes are NOT deployed), the Bitwarden CLI unlocked for
# this shell, and API_DOMAIN (default api.foyeriq.in) already resolving to
# this VM's IP through Cloudflare (needed for the certbot HTTP-01 challenge
# below). VM_IP/VM_USER come from .env at the repo root (see .env.example).
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
BW_ITEM_REDIS="${BW_ITEM_REDIS:-arm-vm-redis}"
BW_ITEM_BWS="${BW_ITEM_BWS:-arm-vm-bws}"
API_DIR="${API_DIR:-$REPO_ROOT/../foyeriq-apis}"
API_REMOTE_DIR="${API_REMOTE_DIR:-/opt/foyeriq-api}"
API_DOMAIN="${API_DOMAIN:-api.foyeriq.in}"
API_PORT="${API_PORT:-4000}"
API_VHOST_PORT="${API_VHOST_PORT:-18445}"
BWS_VERSION="${BWS_VERSION:-1.0.0}"
# Real SMS/email providers (MSG91/Brevo/WhatsApp) aren't wired up yet, so OTP
# login would otherwise be unreachable in production. Defaults to on; once a
# real provider is configured, redeploy with OTP_BYPASS_ENABLED=false.
OTP_BYPASS_ENABLED="${OTP_BYPASS_ENABLED:-true}"
# BWS_PROJECT_ID resolution (env var > "arm-vm-bws" vault item > this default)
# happens later, once bw_require_session has confirmed the vault is reachable.

[[ -d "$API_DIR/.git" ]] || { echo "API_DIR ($API_DIR) is not a git checkout of foyeriq-apis." >&2; exit 1; }
if [[ -n "$(git -C "$API_DIR" status --porcelain)" ]]; then
  echo "$API_DIR has uncommitted changes — this script deploys 'git archive HEAD', so commit/stash first." >&2
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

echo "==> Fetching DB credentials from Bitwarden vault item: $BW_ITEM_POSTGRES"
DB_USER="${DB_USER:-$(bw_field "$BW_ITEM_POSTGRES" app_user)}"
DB_PASSWORD="${DB_PASSWORD:-$(bw_field "$BW_ITEM_POSTGRES" app_user_password)}"
[[ -n "$DB_USER" && -n "$DB_PASSWORD" ]] || { echo "Could not resolve app_user/app_user_password from Bitwarden item $BW_ITEM_POSTGRES." >&2; exit 1; }

CERTBOT_EMAIL="${CERTBOT_EMAIL:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_web_email)}"
[[ -n "$CERTBOT_EMAIL" ]] || { echo "Could not resolve a contact email for certbot from Bitwarden item $BW_ITEM_POSTGRES (pgadmin_web_email)." >&2; exit 1; }

echo "==> Fetching Redis password from Bitwarden vault item: $BW_ITEM_REDIS"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(bw_field "$BW_ITEM_REDIS" redis_password)}"
[[ -n "$REDIS_PASSWORD" ]] || { echo "Could not resolve redis_password from Bitwarden item $BW_ITEM_REDIS." >&2; exit 1; }

echo "==> Resolving Bitwarden Secrets Manager bootstrap credentials"
# Precedence per value: env var > "arm-vm-bws" vault item > hardcoded default
# (BWS_PROJECT_ID only, since the access token has no safe default). The bws
# CLI only needs the access token (it's scoped to one org already) — no
# separate org id is required, unlike the in-app Node SDK.
BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-$(bw_field "$BW_ITEM_BWS" access_token 2>/dev/null || true)}"
VAULT_BWS_PROJECT_ID="$(bw_field "$BW_ITEM_BWS" project_id 2>/dev/null || true)"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-${VAULT_BWS_PROJECT_ID:-22915112-f062-4fe9-ad35-b47d0042f922}}"
[[ -n "$BWS_ACCESS_TOKEN" ]] || {
  echo "Could not resolve BWS_ACCESS_TOKEN (checked Bitwarden vault item '$BW_ITEM_BWS', then the env var)." >&2
  echo "Pass it as an env var the first time: BWS_ACCESS_TOKEN=... $0" >&2
  exit 1
}

echo "==> Requesting/expanding Let's Encrypt cert for $API_DOMAIN (HTTP-01, webroot)"
echo "    Requires $API_DOMAIN to already resolve to this VM through Cloudflare."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d $API_DOMAIN \
  --agree-tos -m $CERTBOT_EMAIL --non-interactive --expand --keep-until-expiring"

echo "==> Shipping API source (git archive HEAD -> $API_REMOTE_DIR/app)"
ssh_run "sudo mkdir -p $API_REMOTE_DIR/app && sudo chown -R \$USER:\$USER $API_REMOTE_DIR"
git -C "$API_DIR" archive --format=tar HEAD | ssh_run "rm -rf $API_REMOTE_DIR/app/* && tar -x -C $API_REMOTE_DIR/app"
echo "    ok ($(git -C "$API_DIR" rev-parse --short HEAD))"

echo "==> Ensuring the bws CLI is installed on the VM (fetches secrets at deploy time, not in-container)"
ssh_run "
  set -e
  if ! command -v bws >/dev/null; then
    command -v unzip >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip
    curl -fsSL -o /tmp/bws.zip https://github.com/bitwarden/sdk-sm/releases/download/bws-v$BWS_VERSION/bws-aarch64-unknown-linux-gnu-$BWS_VERSION.zip
    sudo unzip -o -q /tmp/bws.zip -d /usr/local/bin
    sudo chmod +x /usr/local/bin/bws
    rm -f /tmp/bws.zip
  else
    echo '    already installed: '\$(bws --version)
  fi
"

echo "==> Fetching API secrets from Bitwarden Secrets Manager (project: $BWS_PROJECT_ID)"
# Runs entirely on the VM; the resulting JSON (which contains plaintext secret
# values) is piped straight into the .env file below and never printed here or
# left on disk outside that chmod-600 file.
BWS_SECRETS_FILE="$(mktemp)"
CLEANUP_FILES+=("$BWS_SECRETS_FILE")
ssh_run "BWS_ACCESS_TOKEN='$BWS_ACCESS_TOKEN' bws secret list '$BWS_PROJECT_ID' -o json" > "$BWS_SECRETS_FILE"

echo "==> Writing production .env (DB/Redis creds + bws secrets resolved above)"
# Nothing sensitive here is ever printed or hardcoded in this script: DB_PASSWORD
# and REDIS_PASSWORD came from the Bitwarden vault fetch above, and the rest
# come from the bws secret list. This temp file is chmod 600'd immediately and
# shredded on exit (see CLEANUP_FILES). DB_PASSWORD is excluded from the bws
# dump below since the vault-fetched value above is authoritative.
ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
CLEANUP_FILES+=("$ENV_FILE")
cat > "$ENV_FILE" <<EOF
BWS_REQUIRED=false
NODE_ENV=production
PORT=$API_PORT
API_PREFIX=/api/v1
APP_URL=https://$API_DOMAIN
CORS_ORIGINS=https://foyeriq.in
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=foyeriq_app
DB_SSL=true
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=$REDIS_PASSWORD
SUPPORT_EMAIL=support@foyeriq.in
OTP_BYPASS_ENABLED=$OTP_BYPASS_ENABLED
EOF
jq -r '.[] | select(.key != "DB_PASSWORD") | "\(.key)=\(.value)"' "$BWS_SECRETS_FILE" >> "$ENV_FILE"
scp -i "$SSH_KEY" "$ENV_FILE" "$VM_USER@$VM_IP:$API_REMOTE_DIR/.env" >/dev/null
ssh_run "chmod 600 $API_REMOTE_DIR/.env"
echo "    ok"

echo "==> Building Docker images (runner + builder, for migrations)"
ssh_run "cd $API_REMOTE_DIR/app && sudo docker build -t foyeriq-api:latest . && sudo docker build --target builder -t foyeriq-api:builder ."

echo "==> Running database migrations"
ssh_run "sudo docker run --rm --network host --env-file $API_REMOTE_DIR/.env foyeriq-api:builder npm run db:migrate"

echo "==> Starting API container (docker, host network, bound to 127.0.0.1:$API_PORT only)"
ssh_run "
  sudo docker rm -f foyeriq-api >/dev/null 2>&1 || true
  sudo docker run -d --name foyeriq-api --restart unless-stopped \
    --network host \
    --env-file $API_REMOTE_DIR/.env \
    foyeriq-api:latest >/dev/null
"
echo "    ok"

echo "==> Configuring nginx: internal HTTPS vhost for the API (127.0.0.1:$API_VHOST_PORT -> docker:$API_PORT)"
ssh_run "sudo tee /etc/nginx/conf.d/foyeriq-api.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:$API_VHOST_PORT ssl;
    server_name $API_DOMAIN;
    client_max_body_size 10m;
    ssl_certificate     /etc/letsencrypt/live/$API_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$API_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
}
CONF"

echo "==> Routing \$API_DOMAIN's SNI on public 443 to the API vhost"
ssh_run "sudo mkdir -p /etc/nginx/stream.d/sni.d"
echo "$API_DOMAIN     127.0.0.1:$API_VHOST_PORT;" | ssh_run "sudo tee /etc/nginx/stream.d/sni.d/foyeriq-api.conf >/dev/null"

# Written unconditionally so this always self-heals to the same include-form
# dispatch.conf that setup-postgres.sh, setup-redis.sh, and deploy-site.sh
# also write byte-for-byte identically -- see setup-redis.sh for the fuller
# explanation. Each script only manages its own snippet under
# stream.d/sni.d/*.conf, so whichever of these four runs last can't clobber
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
ssh_run "curl -sf http://127.0.0.1:$API_PORT/health && echo" || echo "    WARNING: local health check failed — check 'sudo docker logs foyeriq-api' on the VM."

echo
echo "==> Done. Verify: https://$API_DOMAIN/health"
echo "    Logs:    ../ssh/connect.sh 'sudo docker logs -f foyeriq-api'"
echo "    Restart: ../ssh/connect.sh 'sudo docker restart foyeriq-api'"
