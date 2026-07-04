#!/usr/bin/env bash
# Installs Redis Open Source and Redis Insight on arm-vm:
#
#   applications on VM -> 127.0.0.1:6379 (Redis, password required)
#   redis.foyeriq.in:443 -> nginx SNI dispatch -> 127.0.0.1:19443
#       -> nginx TLS + Basic Auth -> 127.0.0.1:5540 (Redis Insight, Docker)
#
# Redis never listens on a public interface and port 6379 is not opened in
# either the OCI Security List or iptables. Redis data is persisted with AOF
# under /mnt/data/redis. Redis Insight's own state uses a Docker volume.
#
# Secrets come from the Bitwarden item "arm-vm-redis":
#   redisinsight_domain, redis_password, redisinsight_web_user,
#   redisinsight_web_password, letsencrypt_email
#
# Non-secret config comes from .env:
#   DATA_MOUNT_POINT, BW_ITEM_REDIS
#
# Any value can be supplied as an environment variable instead. Safe to re-run.
#
# Before running, create/proxy the REDISINSIGHT_DOMAIN DNS record in Cloudflare
# to this VM and unlock Bitwarden:
#   export BW_SESSION=$(bw unlock --raw)
#   bash ./oci-infra/setup-redis.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/bw.sh"
source "$REPO_ROOT/lib/firewall.sh"
load_env "$REPO_ROOT"

VM_USER="${VM_USER:-ubuntu}"
INSTANCE_ID="${INSTANCE_ID:-ocid1.instance.oc1.ap-mumbai-1.anrg6ljrxxtcbdycxlgtehdgvfweuo4iz6rjpqzfj3fy7llp4vforeff46sq}"
DATA_MOUNT_POINT="${DATA_MOUNT_POINT:-/mnt/data}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"
BW_ITEM_OCI_KEY="${BW_ITEM_OCI_KEY:-arm-vm-oci-api-key}"
BW_ITEM_REDIS="${BW_ITEM_REDIS:-arm-vm-redis}"
REQUIRED_INGRESS_TCP_PORTS=(80 443)

command -v oci >/dev/null || {
  echo "OCI CLI not found. Install it (e.g. 'brew install oci-cli') first." >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq not found. Install it (e.g. 'brew install jq') first." >&2
  exit 1
}

if [[ ! "$DATA_MOUNT_POINT" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid DATA_MOUNT_POINT: $DATA_MOUNT_POINT" >&2
  exit 1
fi

CLEANUP_FILES=()
cleanup() {
  for f in "${CLEANUP_FILES[@]:-}"; do
    [[ -f "$f" ]] && (shred -u "$f" 2>/dev/null || rm -f "$f")
  done
}
trap cleanup EXIT

NEED_BW=0
for v in REDISINSIGHT_DOMAIN REDIS_PASSWORD REDISINSIGHT_WEB_USER REDISINSIGHT_WEB_PASSWORD LETSENCRYPT_EMAIL; do
  [[ -n "${!v:-}" ]] || NEED_BW=1
done
[[ -n "${SSH_KEY:-}" ]] || NEED_BW=1
[[ -n "${OCI_CLI_USER:-}" ]] || NEED_BW=1
[[ "$NEED_BW" == 1 ]] && bw_require_session

REDISINSIGHT_DOMAIN="${REDISINSIGHT_DOMAIN:-$(bw_field "$BW_ITEM_REDIS" redisinsight_domain)}"
REDIS_PASSWORD="${REDIS_PASSWORD:-$(bw_field "$BW_ITEM_REDIS" redis_password)}"
REDISINSIGHT_WEB_USER="${REDISINSIGHT_WEB_USER:-$(bw_field "$BW_ITEM_REDIS" redisinsight_web_user)}"
REDISINSIGHT_WEB_PASSWORD="${REDISINSIGHT_WEB_PASSWORD:-$(bw_field "$BW_ITEM_REDIS" redisinsight_web_password)}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$(bw_field "$BW_ITEM_REDIS" letsencrypt_email)}"

for v in REDISINSIGHT_DOMAIN REDIS_PASSWORD REDISINSIGHT_WEB_USER REDISINSIGHT_WEB_PASSWORD LETSENCRYPT_EMAIL; do
  [[ -n "${!v}" && "${!v}" != "null" ]] || {
    echo "$v is empty or missing from Bitwarden item '$BW_ITEM_REDIS'." >&2
    exit 1
  }
done
if [[ ! "$REDISINSIGHT_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "Invalid REDISINSIGHT_DOMAIN: $REDISINSIGHT_DOMAIN" >&2
  exit 1
fi
if [[ ! "$REDISINSIGHT_WEB_USER" =~ ^[A-Za-z0-9._%+@-]+$ ]]; then
  echo "REDISINSIGHT_WEB_USER contains unsupported characters." >&2
  exit 1
fi
if [[ ! "$LETSENCRYPT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "Invalid LETSENCRYPT_EMAIL." >&2
  exit 1
fi
if [[ "$REDIS_PASSWORD" == *$'\n'* || "$REDIS_PASSWORD" == *$'\r'* ]]; then
  echo "REDIS_PASSWORD must not contain a newline." >&2
  exit 1
fi
if [[ "$REDISINSIGHT_WEB_PASSWORD" == *$'\n'* || "$REDISINSIGHT_WEB_PASSWORD" == *$'\r'* ]]; then
  echo "REDISINSIGHT_WEB_PASSWORD must not contain a newline." >&2
  exit 1
fi

if [[ -z "${SSH_KEY:-}" ]]; then
  echo "==> Fetching SSH keypair from Bitwarden (item: $BW_ITEM_SSH_KEY)"
  SSH_KEY="$(mktemp)"
  CLEANUP_FILES+=("$SSH_KEY")
  bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
else
  [[ -f "$SSH_KEY" ]] || {
    echo "SSH key not found at $SSH_KEY." >&2
    exit 1
  }
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
else
  [[ -n "${OCI_CLI_KEY_FILE:-}" && -f "$OCI_CLI_KEY_FILE" ]] || {
    echo "OCI_CLI_KEY_FILE not set or not found (required when OCI_CLI_USER is supplied directly)." >&2
    exit 1
  }
fi
COMPARTMENT_ID="$OCI_CLI_TENANCY"

echo "==> Discovering instance's current public IP via OCI API"
VNIC_ID=$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_ID" \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0]."vnic-id"' \
  --raw-output)
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
        and ."tcp-options"."destination-port-range".min == $port
        and ."tcp-options"."destination-port-range".max == $port)]
       | length) == 0
    ))
  | map({
      "is-stateless": false,
      "protocol": "6",
      "source": "0.0.0.0/0",
      "source-type": "CIDR_BLOCK",
      "tcp-options": {"destination-port-range": {"min": ., "max": .}}
    })
  | $existing + .
' <<<"$CURRENT_INGRESS")
if [[ "$(jq 'length' <<<"$MERGED_INGRESS")" != "$(jq 'length' <<<"$CURRENT_INGRESS")" ]]; then
  echo "    adding missing port(s)"
  oci network security-list update \
    --security-list-id "$SECURITY_LIST_ID" \
    --ingress-security-rules "$MERGED_INGRESS" \
    --force >/dev/null
else
  echo "    already present"
fi
echo "    ok"

ssh_run() {
  ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"
}

echo "==> Verifying the data block volume is mounted at $DATA_MOUNT_POINT"
ssh_run "findmnt -M '$DATA_MOUNT_POINT' >/dev/null || {
  echo '$DATA_MOUNT_POINT is not a mounted filesystem. Run ./oci-infra/setup.sh first.' >&2
  exit 1
}"
echo "    ok"

echo "==> Installing latest stable Redis from the official Redis APT repository"
ssh_run '
  set -euo pipefail
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lsb-release curl gpg
  if [[ ! -f /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
    curl -fsSL https://packages.redis.io/gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    sudo chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
  fi
  CODENAME=$(. /etc/os-release && printf "%s" "$VERSION_CODENAME")
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $CODENAME main" \
    | sudo tee /etc/apt/sources.list.d/redis.list >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis
  redis-server --version
'

# The password is piped over stdin (not interpolated into the command string)
# so it never appears in `ps`/`/proc/<pid>/cmdline` on either the local or
# remote machine. It's then escaped for Redis's quoted config syntax and
# written to a root-owned file readable only by the redis group.
echo "==> Configuring Redis: loopback only, password required, AOF on $DATA_MOUNT_POINT"
printf '%s' "$REDIS_PASSWORD" | ssh_run "
  set -euo pipefail
  REDIS_PASSWORD=\$(cat)
  REDIS_PASSWORD_ESCAPED=\${REDIS_PASSWORD//\\\\/\\\\\\\\}
  REDIS_PASSWORD_ESCAPED=\${REDIS_PASSWORD_ESCAPED//\\\"/\\\\\\\"}

  sudo install -d -o redis -g redis -m 750 '$DATA_MOUNT_POINT/redis'
  {
    echo 'bind 127.0.0.1 -::1'
    echo 'protected-mode yes'
    echo 'port 6379'
    printf 'requirepass \"%s\"\\n' \"\$REDIS_PASSWORD_ESCAPED\"
    echo 'appendonly yes'
    echo 'appendfsync everysec'
    echo 'dir $DATA_MOUNT_POINT/redis'
  } | sudo tee /etc/redis/foyeriq.conf >/dev/null
  sudo chown root:redis /etc/redis/foyeriq.conf
  sudo chmod 640 /etc/redis/foyeriq.conf

  sudo grep -qxF 'include /etc/redis/foyeriq.conf' /etc/redis/redis.conf || \
    echo 'include /etc/redis/foyeriq.conf' | sudo tee -a /etc/redis/redis.conf >/dev/null

  sudo systemctl enable redis-server >/dev/null
  sudo systemctl restart redis-server
  for i in \$(seq 1 15); do
    REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -qx PONG && break
    if [[ \$i -eq 15 ]]; then
      echo 'Redis did not respond PONG within 15s of restart (still loading AOF?).' >&2
      exit 1
    fi
    sleep 1
  done
  if ss -ltnH '( sport = :6379 )' | awk '{print \$4}' | grep -qvE '^(127\\.0\\.0\\.1|\\[::1\\]):6379$'; then
    echo 'Redis is listening on a non-loopback address; refusing to continue.' >&2
    exit 1
  fi
"
echo "    ok"

echo "==> Ensuring Docker, nginx, certbot, and Basic Auth tooling are installed"
ssh_run "
  set -e
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    sudo usermod -aG docker '$VM_USER'
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot apache2-utils
"

echo "==> Requesting/renewing the TLS certificate for $REDISINSIGHT_DOMAIN"
echo "    The Cloudflare DNS record must already be proxied to $VM_IP."
ssh_run "sudo certbot certonly --webroot -w /var/www/html \
  -d '$REDISINSIGHT_DOMAIN' \
  --agree-tos -m '$LETSENCRYPT_EMAIL' --non-interactive --keep-until-expiring"
echo "    ok"

echo "==> Starting Redis Insight on loopback port 5540"
ssh_run '
  set -e
  sudo docker pull redis/redisinsight:latest >/dev/null
  sudo docker rm -f redisinsight >/dev/null 2>&1 || true
  sudo docker volume create redisinsight-data >/dev/null
  sudo docker run -d \
    --name redisinsight \
    --restart unless-stopped \
    --network host \
    -e RI_APP_HOST=127.0.0.1 \
    -e RI_APP_PORT=5540 \
    -v redisinsight-data:/data \
    redis/redisinsight:latest >/dev/null
'
echo "    ok"

echo "==> Configuring Nginx TLS reverse proxy and Basic Auth for Redis Insight"
printf '%s' "$REDISINSIGHT_WEB_PASSWORD" | ssh_run "
  set -euo pipefail
  WEB_PASSWORD=\$(cat)
  printf '%s\\n' \"\$WEB_PASSWORD\" \
    | sudo htpasswd -i -c -B /etc/nginx/.redisinsight.htpasswd '$REDISINSIGHT_WEB_USER' >/dev/null
  sudo chown root:www-data /etc/nginx/.redisinsight.htpasswd
  sudo chmod 640 /etc/nginx/.redisinsight.htpasswd

  sudo tee /etc/nginx/conf.d/redisinsight.conf >/dev/null <<CONF
server {
    listen 127.0.0.1:19443 ssl;
    server_name $REDISINSIGHT_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$REDISINSIGHT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$REDISINSIGHT_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    auth_basic \"Redis Insight\";
    auth_basic_user_file /etc/nginx/.redisinsight.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:5540;
        proxy_http_version 1.1;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Authorization \"\";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
CONF

  sudo mkdir -p /etc/nginx/stream.d/sni.d
  echo '$REDISINSIGHT_DOMAIN     127.0.0.1:19443;' \
    | sudo tee /etc/nginx/stream.d/sni.d/redisinsight.conf >/dev/null
"

echo "==> Ensuring Nginx stream SNI dispatch is present on public port 443"
# Written unconditionally (not guarded by a file-existence check) so this
# always self-heals to the same include-form dispatch.conf that
# setup-postgres.sh and apps/site/deploy.sh also write byte-for-byte
# identically — whichever of these scripts runs last wins, but since all
# three emit the same content, the result is always the correct, extensible
# form. A guarded/conditional write here previously caused this script's
# sni.d-aware template to be silently skipped whenever setup-postgres.sh had
# already created an older, non-sni.d dispatch.conf first.
ssh_run '
  set -e
  sudo mkdir -p /etc/nginx/stream.d/sni.d
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
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx

  printf "#!/bin/sh\nsystemctl reload nginx\n" \
    | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  sudo systemctl enable --now certbot.timer
'
echo "    ok"

echo "==> Removing any host firewall rule that may expose Redis directly"
ssh_run '
  while sudo iptables -C INPUT -p tcp --dport 6379 -m state --state NEW -j ACCEPT 2>/dev/null; do
    sudo iptables -D INPUT -p tcp --dport 6379 -m state --state NEW -j ACCEPT
  done
  if command -v netfilter-persistent >/dev/null; then
    sudo netfilter-persistent save
  fi
'
apply_cloudflare_lock "$SCRIPT_DIR/cf-lock-iptables.sh"

echo
echo "==> Done"
echo "    Redis:         127.0.0.1:6379 (password required; not public)"
echo "    Redis data:    $DATA_MOUNT_POINT/redis (AOF, fsync every second)"
echo "    Redis Insight: https://$REDISINSIGHT_DOMAIN"
echo "    Web login:     $REDISINSIGHT_WEB_USER / <redisinsight_web_password>"
echo
echo "    In Redis Insight, add a database with:"
echo "      host=127.0.0.1 port=6379 username=default password=<redis_password>"
