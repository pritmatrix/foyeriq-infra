#!/usr/bin/env bash
# Installs the latest stable PostgreSQL on arm-vm and stands up pgAdmin4,
# exposing BOTH to the internet over a single port, 443, and nothing else:
#
#   client --TLS--> nginx:443 (stream, ssl_preread SNI dispatch)
#                      |-- SNI = $PGADMIN_DOMAIN --TLS-terminated--> 127.0.0.1:18443 (nginx http vhost) -> 127.0.0.1:5050 (pgAdmin4, docker)
#                      '-- anything else (incl. no SNI)  --raw bytes, untouched--> 127.0.0.1:5432 (postgres, terminates its own TLS)
#
# Why Postgres can't just sit behind a normal nginx TLS-terminating stream
# proxy on 443 (which is what earlier versions of this script did): the
# Postgres wire protocol either sends a plaintext SSLRequest probe before
# the TLS handshake, or (with newer libpq, sslnegotiation=direct) negotiates
# TLS directly via ALPN "postgresql" — neither looks like a bare TLS
# ClientHello nginx can blindly terminate, and nginx doesn't speak the
# Postgres ALPN protocol. So instead nginx's stream module runs in
# `ssl_preread` mode: it peeks at the SNI of an incoming TLS ClientHello
# *without* terminating TLS, forwarding the raw encrypted bytes on
# untouched. If the SNI is $PGADMIN_DOMAIN, it forwards to a small internal
# nginx vhost that actually terminates TLS and reverse-proxies plain HTTP
# to pgAdmin4. Anything else — including Postgres's classic plaintext
# SSLRequest probe, which ssl_preread can't parse as TLS at all and so
# falls through to the map's `default` — goes straight to Postgres, which
# terminates its own TLS itself using the same Let's Encrypt cert. Postgres
# only ever binds to localhost:5432; 5432 is never opened externally.
#
# Cert is a single Let's Encrypt cert covering both domains, requested via
# certbot's HTTP-01 (webroot) challenge against the default nginx site on
# port 80 — fully automated, no DNS provider API needed. certbot's systemd
# timer renews it unattended; deploy hooks reload nginx and refresh
# Postgres's copy of the cert + restart it so the renewed cert takes effect.
#
# The VM is Cloudflare-proxied, so this also locks the web ports (80/443) to
# Cloudflare's origin IP ranges (see lib/firewall.sh) — nobody can bypass
# Cloudflare by hitting the origin directly, and as a side effect Postgres is
# no longer reachable on 443 from arbitrary clients (use an SSH tunnel; see the
# closing notes). On top of that a hardening pass: the Postgres SUPERUSER role
# is confined to local/SSH access only (never reachable over the network); a
# separate, unprivileged app role is what pgAdmin4 and tunneled clients use;
# statement/idle timeouts bound abuse from a compromised credential;
# connection/disconnection logging is on; TLS is pinned to 1.2+; and OS +
# Postgres security patches install unattended.
#
# Usage:
#   ./oci-infra/setup-postgres.sh
#
# All config (domains, role names, passwords, pgAdmin login) is pulled from
# the Bitwarden item "arm-vm-postgres" (see lib/bw.sh for the field names).
# Override any of DOMAIN, PGADMIN_DOMAIN, PG_SUPERUSER, PG_SUPERUSER_PASSWORD,
# APP_USER, APP_USER_PASSWORD, PGADMIN_WEB_EMAIL, PGADMIN_WEB_PASSWORD as env
# vars to bypass Bitwarden for a given field.
#
#   PG_SUPERUSER            Postgres superuser role name (created if missing). Local/SSH access
#                           only — never reachable over the network. Use `ssh` in, then
#                           `sudo -u postgres psql` (or `psql -U $PG_SUPERUSER` as the postgres
#                           OS user) for true admin work.
#   APP_USER                Unprivileged Postgres role for everyday access — this is what
#                           external clients, apps, and pgAdmin4 "Add Server" should use
#
# The instance's public IP and the cloud-level Security List (TCP 80/443
# ingress) are discovered/ensured via the OCI API, same as setup.sh — this
# script can run standalone without setup.sh having run first. The SSH
# keypair and OCI API signing key also come from Bitwarden, not local
# files. Requires the Bitwarden CLI logged in and unlocked for this shell
# (`export BW_SESSION=$(bw unlock --raw)`), plus the OCI CLI and jq
# (`brew install oci-cli jq`).
#
# Non-secret config (instance OCID, Bitwarden item names) comes from .env
# at the repo root — see .env.example — falling back to the defaults below
# if .env is absent.
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
INSTANCE_ID="${INSTANCE_ID:-ocid1.instance.oc1.ap-mumbai-1.anrg6ljrxxtcbdycxlgtehdgvfweuo4iz6rjpqzfj3fy7llp4vforeff46sq}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"
BW_ITEM_OCI_KEY="${BW_ITEM_OCI_KEY:-arm-vm-oci-api-key}"
BW_ITEM_POSTGRES="${BW_ITEM_POSTGRES:-arm-vm-postgres}"
REQUIRED_INGRESS_TCP_PORTS=(80 443)

if ! command -v oci >/dev/null; then
  echo "OCI CLI not found. Install it (e.g. 'brew install oci-cli') first." >&2
  exit 1
fi
if ! command -v jq >/dev/null; then
  echo "jq not found. Install it (e.g. 'brew install jq') first." >&2
  exit 1
fi

CLEANUP_FILES=()
cleanup() { for f in "${CLEANUP_FILES[@]:-}"; do [[ -f "$f" ]] && (shred -u "$f" 2>/dev/null || rm -f "$f"); done; }
trap cleanup EXIT

NEED_BW=0
for v in DOMAIN PGADMIN_DOMAIN PG_SUPERUSER PG_SUPERUSER_PASSWORD APP_USER APP_USER_PASSWORD PGADMIN_WEB_EMAIL PGADMIN_WEB_PASSWORD; do
  [[ -n "${!v:-}" ]] || NEED_BW=1
done
[[ -n "${SSH_KEY:-}" ]] || NEED_BW=1
[[ -n "${OCI_CLI_USER:-}" ]] || NEED_BW=1
[[ "$NEED_BW" == 1 ]] && bw_require_session

DOMAIN="${DOMAIN:-$(bw_field "$BW_ITEM_POSTGRES" domain)}"
PGADMIN_DOMAIN="${PGADMIN_DOMAIN:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_domain)}"
PG_SUPERUSER="${PG_SUPERUSER:-$(bw_field "$BW_ITEM_POSTGRES" pg_superuser)}"
PG_SUPERUSER_PASSWORD="${PG_SUPERUSER_PASSWORD:-$(bw_field "$BW_ITEM_POSTGRES" pg_superuser_password)}"
APP_USER="${APP_USER:-$(bw_field "$BW_ITEM_POSTGRES" app_user)}"
APP_USER_PASSWORD="${APP_USER_PASSWORD:-$(bw_field "$BW_ITEM_POSTGRES" app_user_password)}"
PGADMIN_WEB_EMAIL="${PGADMIN_WEB_EMAIL:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_web_email)}"
PGADMIN_WEB_PASSWORD="${PGADMIN_WEB_PASSWORD:-$(bw_field "$BW_ITEM_POSTGRES" pgadmin_web_password)}"

if [[ -z "${SSH_KEY:-}" ]]; then
  echo "==> Fetching SSH keypair from Bitwarden (item: $BW_ITEM_SSH_KEY)"
  SSH_KEY="$(mktemp)"
  CLEANUP_FILES+=("$SSH_KEY")
  bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
else
  [[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY." >&2; exit 1; }
fi

if [[ -z "${OCI_CLI_USER:-}" ]]; then
  echo "==> Fetching OCI API key from Bitwarden (item: $BW_ITEM_OCI_KEY)"
  OCI_KEY_FILE="$(mktemp)"
  CLEANUP_FILES+=("$OCI_KEY_FILE")
  bw_write_secret_file "$BW_ITEM_OCI_KEY" "$OCI_KEY_FILE"
  export OCI_CLI_KEY_FILE="$OCI_KEY_FILE"
  export OCI_CLI_USER="$(bw_field "$BW_ITEM_OCI_KEY" user_ocid)"
  export OCI_CLI_FINGERPRINT="$(bw_field "$BW_ITEM_OCI_KEY" fingerprint)"
  export OCI_CLI_TENANCY="$(bw_field "$BW_ITEM_OCI_KEY" tenancy_ocid)"
  export OCI_CLI_REGION="$(bw_field "$BW_ITEM_OCI_KEY" region)"
  export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
fi
COMPARTMENT_ID="$OCI_CLI_TENANCY"

echo "==> Discovering instance's current public IP via OCI API"
VNIC_ID=$(oci compute vnic-attachment list --compartment-id "$COMPARTMENT_ID" --instance-id "$INSTANCE_ID" \
  --query 'data[0]."vnic-id"' --raw-output)
VNIC=$(oci network vnic get --vnic-id "$VNIC_ID" \
  --query 'data.{publicIp:"public-ip", subnetId:"subnet-id"}')
VM_IP="${VM_IP:-$(jq -r '.publicIp' <<<"$VNIC")}"
SUBNET_ID=$(jq -r '.subnetId' <<<"$VNIC")
echo "    $VM_IP"

echo "==> Ensuring Security List allows inbound TCP ${REQUIRED_INGRESS_TCP_PORTS[*]}"
SECURITY_LIST_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" \
  --query 'data."security-list-ids"[0]' --raw-output)
CURRENT_INGRESS=$(oci network security-list get --security-list-id "$SECURITY_LIST_ID" \
  --query 'data."ingress-security-rules"')
MERGED_INGRESS=$(jq --argjson ports "$(printf '%s\n' "${REQUIRED_INGRESS_TCP_PORTS[@]}" | jq -R 'tonumber' | jq -s .)" '
  . as $existing
  | $ports
  | map(. as $port | select(
      ([$existing[] | select(.protocol == "6" and .source == "0.0.0.0/0"
        and ."tcp-options"."destination-port-range".min == $port and ."tcp-options"."destination-port-range".max == $port)]
       | length) == 0
    ))
  | map({
      "is-stateless": false, "protocol": "6", "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK",
      "tcp-options": {"destination-port-range": {"min": ., "max": .}}
    })
  | $existing + .
' <<<"$CURRENT_INGRESS")
if [[ "$(jq 'length' <<<"$MERGED_INGRESS")" != "$(jq 'length' <<<"$CURRENT_INGRESS")" ]]; then
  echo "    adding missing port(s)"
  oci network security-list update --security-list-id "$SECURITY_LIST_ID" \
    --ingress-security-rules "$MERGED_INGRESS" --force >/dev/null
else
  echo "    already present"
fi
echo "    ok"

ssh_run() { ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"; }

echo "==> Installing latest stable PostgreSQL (PGDG repo)"
ssh_run '
  set -e
  if ! command -v psql >/dev/null; then
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    . /etc/os-release
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql
  else
    echo "    already installed: $(psql --version)"
  fi
'

echo "==> Ensuring Postgres data directory lives on the /mnt/data block volume, not the 50GB boot disk"
ssh_run "
  set -e
  DATADIR=\$(sudo -u postgres psql -tAc 'SHOW data_directory;' | xargs)
  if [[ \"\$DATADIR\" != /mnt/data/* ]]; then
    PGVERSION=\$(sudo -u postgres psql -tAc 'SHOW server_version_num;' | cut -c1-2)
    NEWDIR=\"/mnt/data/postgresql/\${PGVERSION}/main\"
    echo \"    moving \$DATADIR -> \$NEWDIR\"
    sudo systemctl stop postgresql
    sudo mkdir -p \"\$(dirname \"\$NEWDIR\")\"
    sudo rsync -a \"\$DATADIR/\" \"\$NEWDIR/\"
    sudo chown -R postgres:postgres /mnt/data/postgresql
    sudo chmod 700 \"\$NEWDIR\"
    PGCONF=/etc/postgresql/\${PGVERSION}/main/postgresql.conf
    sudo sed -i \"s|^data_directory = .*|data_directory = '\$NEWDIR'|\" \"\$PGCONF\"
    grep -q '^data_directory' \"\$PGCONF\" || echo \"data_directory = '\$NEWDIR'\" | sudo tee -a \"\$PGCONF\" >/dev/null
    sudo mv \"\$DATADIR\" \"\${DATADIR}.bak\"
    sudo systemctl start postgresql
  else
    echo \"    already on /mnt/data: \$DATADIR\"
  fi
"
echo "    ok"

echo "==> Installing nginx + certbot"
ssh_run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot"

echo "==> Requesting/expanding cert for $DOMAIN + $PGADMIN_DOMAIN via HTTP-01 (webroot)"
echo "    Uses the existing default nginx site on port 80; both domains must already resolve here."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d $DOMAIN -d $PGADMIN_DOMAIN \
  --agree-tos -m $PGADMIN_WEB_EMAIL --non-interactive --expand --keep-until-expiring"
echo "    ok"

echo "==> Configuring Postgres: localhost only, SSL via the Let's Encrypt cert, require SSL, hardened defaults"
ssh_run "
  set -e
  PGCONF=\$(sudo -u postgres psql -tAc 'SHOW config_file;')
  PGHBA=\$(sudo -u postgres psql -tAc 'SHOW hba_file;')
  PGDIR=\$(dirname \"\$PGCONF\")

  sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem \"\$PGDIR/server.crt\"
  sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem \"\$PGDIR/server.key\"
  sudo chown postgres:postgres \"\$PGDIR/server.crt\" \"\$PGDIR/server.key\"
  sudo chmod 644 \"\$PGDIR/server.crt\"
  sudo chmod 600 \"\$PGDIR/server.key\"

  sudo sed -i \"s/^#\\?listen_addresses.*/listen_addresses = 'localhost'/\" \"\$PGCONF\"
  sudo grep -vE \"^(ssl = on|ssl_cert_file = |ssl_key_file = |ssl_min_protocol_version = |log_connections = |log_disconnections = |statement_timeout = |idle_in_transaction_session_timeout = )\" \"\$PGCONF\" | sudo tee \"\${PGCONF}.tmp\" >/dev/null
  sudo mv \"\${PGCONF}.tmp\" \"\$PGCONF\"
  {
    echo \"ssl = on\"
    echo \"ssl_cert_file = '\$PGDIR/server.crt'\"
    echo \"ssl_key_file = '\$PGDIR/server.key'\"
    echo \"ssl_min_protocol_version = 'TLSv1.2'\"
    echo \"log_connections = on\"
    echo \"log_disconnections = on\"
    echo \"statement_timeout = '5min'\"
    echo \"idle_in_transaction_session_timeout = '5min'\"
  } | sudo tee -a \"\$PGCONF\" >/dev/null

  # Only the unprivileged APP_USER is reachable over the network (via nginx, which always
  # appears as 127.0.0.1 to Postgres). The superuser role has no network pg_hba entry at all —
  # it's local-socket (peer) only, i.e. SSH in first.
  sudo grep -vE '^hostssl +all +all +127\.0\.0\.1/32' \"\$PGHBA\" | sudo tee \"\${PGHBA}.tmp\" >/dev/null
  sudo mv \"\${PGHBA}.tmp\" \"\$PGHBA\"
  sudo grep -qxF 'hostssl all             $APP_USER         127.0.0.1/32            scram-sha-256' \"\$PGHBA\" || \
    echo 'hostssl all             $APP_USER         127.0.0.1/32            scram-sha-256' | sudo tee -a \"\$PGHBA\" >/dev/null

  sudo systemctl restart postgresql
"
echo "    ok"

echo "==> Creating/updating superuser role (local/SSH access only — no network pg_hba entry)"
ssh_run "sudo -u postgres psql -v ON_ERROR_STOP=1 -c \"
  DO \\\$\\\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_SUPERUSER') THEN
      CREATE ROLE \\\"$PG_SUPERUSER\\\" LOGIN SUPERUSER PASSWORD '$PG_SUPERUSER_PASSWORD';
    ELSE
      ALTER ROLE \\\"$PG_SUPERUSER\\\" PASSWORD '$PG_SUPERUSER_PASSWORD';
    END IF;
  END
  \\\$\\\$;
\""
echo "    ok"

echo "==> Creating/updating unprivileged app role (this is what external clients + pgAdmin4 should use)"
ssh_run "sudo -u postgres psql -v ON_ERROR_STOP=1 -c \"
  DO \\\$\\\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USER') THEN
      CREATE ROLE \\\"$APP_USER\\\" LOGIN PASSWORD '$APP_USER_PASSWORD';
    ELSE
      ALTER ROLE \\\"$APP_USER\\\" PASSWORD '$APP_USER_PASSWORD';
    END IF;
  END
  \\\$\\\$;
  GRANT CONNECT ON DATABASE postgres TO \\\"$APP_USER\\\";
  GRANT USAGE, CREATE ON SCHEMA public TO \\\"$APP_USER\\\";
\""
echo "    ok"

echo "==> Removing any 5432 / stale 8443 firewall rules from older versions of this script"
ssh_run '
  sudo iptables -D INPUT -p tcp --dport 5432 -m state --state NEW -j ACCEPT 2>/dev/null || true
  sudo iptables -D INPUT -p tcp --dport 8443 -m state --state NEW -j ACCEPT 2>/dev/null || true
  sudo netfilter-persistent save
'
echo "    ok"

# Lock 80/443 to Cloudflare's origin ranges (and drop the old per-source-IP
# hashlimit, which is counterproductive behind Cloudflare — "source IP" would
# be a shared Cloudflare edge). Rate-limiting/DDoS protection is Cloudflare's
# job now; this just ensures nobody reaches the origin except via Cloudflare.
apply_cloudflare_lock "$SCRIPT_DIR/cf-lock-iptables.sh"

echo "==> Enabling unattended security upgrades (OS + PGDG Postgres packages)"
ssh_run "
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null
  sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-pgdg >/dev/null <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    \"origin=Ubuntu,archive=\\\${distro_codename}-security\";
    \"origin=Ubuntu,archive=\\\${distro_codename}-updates\";
    \"origin=PostgreSQL,codename=\\\${distro_codename}-pgdg\";
};
Unattended-Upgrade::Automatic-Reboot \"false\";
EOF
  sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
EOF
  sudo systemctl enable --now unattended-upgrades
"
echo "    ok"

echo "==> Ensuring Docker is installed (for the pgAdmin4 container)"
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

echo "==> Starting pgAdmin4 (docker, bound to localhost:5050 only)"
ssh_run "
  sudo docker rm -f pgadmin4 >/dev/null 2>&1 || true
  sudo docker volume create pgadmin4-data >/dev/null
  sudo docker run -d --name pgadmin4 --restart unless-stopped \
    -p 127.0.0.1:5050:80 \
    -e PGADMIN_DEFAULT_EMAIL='$PGADMIN_WEB_EMAIL' \
    -e PGADMIN_DEFAULT_PASSWORD='$PGADMIN_WEB_PASSWORD' \
    -v pgadmin4-data:/var/lib/pgadmin \
    dpage/pgadmin4:latest >/dev/null
"
echo "    ok"

echo "==> Configuring nginx: internal HTTPS vhost for pgAdmin4 (127.0.0.1:18443 -> docker:5050), TLS 1.2+ only"
ssh_run "
  sudo sed -i 's/ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/' /etc/nginx/nginx.conf
  sudo tee /etc/nginx/conf.d/pgadmin.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:18443 ssl;
    server_name $PGADMIN_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5050;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
}
CONF
"

echo "==> Configuring nginx stream module: SNI dispatch on public 443"
echo "    (nginx.conf only allows a 'stream' block at top level, not inside 'http', so it's wired in separately)"
ssh_run '
  set -e
  sudo mkdir -p /etc/nginx/stream.d
  grep -q "include /etc/nginx/stream.d/\*.conf;" /etc/nginx/nginx.conf || \
    sudo sed -i "/^http {/i stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n" /etc/nginx/nginx.conf
  sudo rm -f /etc/nginx/stream.d/postgres.conf
'
ssh_run "sudo tee /etc/nginx/stream.d/dispatch.conf >/dev/null <<CONF
map \\\$ssl_preread_server_name \\\$backend {
    $PGADMIN_DOMAIN     127.0.0.1:18443;
    default             127.0.0.1:5432;
}
server {
    listen 443;
    ssl_preread on;
    proxy_pass \\\$backend;
}
CONF"

ssh_run 'sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx'
echo "    ok"

echo "==> Registering certbot renewal hooks (reload nginx, refresh Postgres's cert copy + restart)"
ssh_run "
  sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  PGDIR=\$(sudo -u postgres psql -tAc 'SHOW config_file;' | xargs dirname)
  printf '#!/bin/sh\nset -e\ncp /etc/letsencrypt/live/$DOMAIN/fullchain.pem %s/server.crt\ncp /etc/letsencrypt/live/$DOMAIN/privkey.pem %s/server.key\nchown postgres:postgres %s/server.crt %s/server.key\nchmod 644 %s/server.crt\nchmod 600 %s/server.key\nsystemctl restart postgresql\n' \"\$PGDIR\" \"\$PGDIR\" \"\$PGDIR\" \"\$PGDIR\" \"\$PGDIR\" \"\$PGDIR\" | sudo tee /etc/letsencrypt/renewal-hooks/deploy/refresh-postgres-cert.sh >/dev/null
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/refresh-postgres-cert.sh

  sudo systemctl enable --now certbot.timer
"
echo "    ok"

echo
echo "==> Done. The origin's web ports (80/443) now accept Cloudflare ranges only,"
echo "    so Postgres is no longer reachable on 443 directly. Connect via an SSH tunnel"
echo "    with the unprivileged app role:"
echo "    ../ssh/connect.sh -L 5432:127.0.0.1:5432"
echo "    psql \"host=127.0.0.1 port=5432 dbname=postgres user=$APP_USER sslmode=require\""
echo
echo "==> For true superuser/admin work:"
echo "    ../ssh/connect.sh"
echo "    sudo -u postgres psql          # peer-auth, no password, always works locally"
echo "    (the $PG_SUPERUSER role has no network pg_hba entry — it cannot log in remotely at all)"
echo
echo "==> pgAdmin4 web UI:"
echo "    https://$PGADMIN_DOMAIN  (login: $PGADMIN_WEB_EMAIL)"
echo "    Add a server inside pgAdmin4 pointing at host=127.0.0.1 port=5432, user=$APP_USER — it runs"
echo "    on the same VM as Postgres, so it reaches it directly rather than through the 443 proxy."
echo
echo "    Cert auto-renews via certbot.timer (HTTP-01 against port 80); deploy hooks reload nginx"
echo "    and refresh + restart Postgres so both pick up the renewed cert automatically."
echo
echo "    Only 80 and 443 need to be open — 5432 is never exposed externally."
