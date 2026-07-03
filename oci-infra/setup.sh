#!/usr/bin/env bash
# Post-provision setup for arm-vm. Run this against an already-existing VM
# (fresh boot, OS reinstall, or re-setup after losing the instance) to
# reapply everything cloud-init would have done on first boot:
#   1. Discover the instance's current public IP via the OCI API (Always
#      Free A1 instances get an ephemeral public IP that can change across
#      stop/start — this avoids a stale hardcoded IP going silently wrong).
#   2. Ensure the VCN's Security List allows inbound TCP 22/80/443 — the
#      cloud-level firewall. This is the layer that bit us before: iptables
#      alone isn't enough, since OCI drops disallowed traffic before it
#      ever reaches the instance, regardless of guest firewall rules.
#   3. Ensure our public key is in ubuntu's authorized_keys.
#   4. Open the guest-level iptables firewall for HTTP (80) and HTTPS
#      (443), persisted across reboots. OCI images ship a REJECT rule near
#      the top of INPUT, so rules are PREPENDED (no position number) to
#      evaluate first.
#   5. Install Docker Engine + the official compose plugin, and add
#      `ubuntu` to the docker group.
#   6. Create (if missing) and attach a 150GB Always Free-eligible block
#      volume, then format + mount it on the VM at /mnt/data. 150GB here
#      plus the 50GB boot volume maxes out OCI's 200GB Always Free block
#      storage allowance (Balanced performance, 10 VPUs/GB — the free
#      tier's performance level; anything higher bills).
#
# Secrets (the SSH keypair and the OCI API signing key) live in Bitwarden,
# not local files — see lib/bw.sh. Requires the Bitwarden CLI logged in and
# unlocked for this shell (`export BW_SESSION=$(bw unlock --raw)`), plus
# the OCI CLI and jq installed (`brew install oci-cli jq`). Set SSH_KEY=
# /path/to/key to bypass Bitwarden and use a local key file instead.
#
# Non-secret config (instance OCID, availability domain, volume settings,
# Bitwarden item names) comes from .env at the repo root — see
# .env.example — falling back to the defaults below if .env is absent.
#
# Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/env.sh"
source "$REPO_ROOT/lib/bw.sh"
load_env "$REPO_ROOT"

VM_USER="${VM_USER:-ubuntu}"
INSTANCE_ID="${INSTANCE_ID:-ocid1.instance.oc1.ap-mumbai-1.anrg6ljrxxtcbdycxlgtehdgvfweuo4iz6rjpqzfj3fy7llp4vforeff46sq}"
AVAILABILITY_DOMAIN="${AVAILABILITY_DOMAIN:-GsWm:AP-MUMBAI-1-AD-1}"
DATA_VOLUME_NAME="${DATA_VOLUME_NAME:-arm-vm-data}"
DATA_VOLUME_SIZE_GB="${DATA_VOLUME_SIZE_GB:-150}"
DATA_MOUNT_POINT="${DATA_MOUNT_POINT:-/mnt/data}"
BW_ITEM_SSH_KEY="${BW_ITEM_SSH_KEY:-arm-vm-ssh-key}"
BW_ITEM_OCI_KEY="${BW_ITEM_OCI_KEY:-arm-vm-oci-api-key}"
REQUIRED_INGRESS_TCP_PORTS=(22 80 443)

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

if [[ -z "${SSH_KEY:-}" ]]; then
  bw_require_session
  echo "==> Fetching SSH keypair from Bitwarden (item: $BW_ITEM_SSH_KEY)"
  SSH_KEY="$(mktemp)"
  CLEANUP_FILES+=("$SSH_KEY")
  bw_write_secret_file "$BW_ITEM_SSH_KEY" "$SSH_KEY"
  SSH_PUB_KEY_CONTENT="$(bw_field "$BW_ITEM_SSH_KEY" public_key)"
else
  [[ -f "$SSH_KEY" ]] || { echo "SSH key not found at $SSH_KEY." >&2; exit 1; }
  [[ -f "$SSH_KEY.pub" ]] || { echo "Public key not found at $SSH_KEY.pub" >&2; exit 1; }
  SSH_PUB_KEY_CONTENT="$(cat "$SSH_KEY.pub")"
fi

if [[ -z "${OCI_CLI_USER:-}" ]]; then
  bw_require_session
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

echo "==> SSH: ensuring public key is authorized"
ssh_run "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
  grep -qxF '$SSH_PUB_KEY_CONTENT' ~/.ssh/authorized_keys || echo '$SSH_PUB_KEY_CONTENT' >> ~/.ssh/authorized_keys && \
  chmod 600 ~/.ssh/authorized_keys"
echo "    ok"

echo "==> Firewall: opening 80/443, persisting rules"
ssh_run '
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netfilter-persistent iptables-persistent >/dev/null && \
  sudo iptables -C INPUT -p tcp --dport 80  -m state --state NEW -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 80  -m state --state NEW -j ACCEPT && \
  sudo iptables -C INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT && \
  sudo netfilter-persistent save
'
echo "    ok"

echo "==> Docker: installing engine + compose plugin"
ssh_run '
  if command -v docker >/dev/null; then
    echo "    already installed: $(docker --version)"
  else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && \
    sudo sh /tmp/get-docker.sh && \
    sudo usermod -aG docker ubuntu
  fi
'

echo "==> Block storage: ensuring $DATA_VOLUME_SIZE_GB GB data volume exists and is attached"
VOLUME_ID=$(oci bv volume list --compartment-id "$COMPARTMENT_ID" --availability-domain "$AVAILABILITY_DOMAIN" \
  --display-name "$DATA_VOLUME_NAME" --lifecycle-state AVAILABLE \
  --query 'data[0].id' --raw-output 2>/dev/null || true)

if [[ -z "$VOLUME_ID" || "$VOLUME_ID" == "null" ]]; then
  echo "    creating volume $DATA_VOLUME_NAME ($DATA_VOLUME_SIZE_GB GB, balanced/10 VPUs-per-GB — the Always Free performance tier)"
  VOLUME_ID=$(oci bv volume create \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --display-name "$DATA_VOLUME_NAME" \
    --size-in-gbs "$DATA_VOLUME_SIZE_GB" \
    --vpus-per-gb 10 \
    --wait-for-state AVAILABLE \
    --query 'data.id' --raw-output)
else
  echo "    volume already exists: $VOLUME_ID"
fi

ATTACHMENT_STATE=$(oci compute volume-attachment list --compartment-id "$COMPARTMENT_ID" --instance-id "$INSTANCE_ID" \
  --query "data[?\"volume-id\"=='$VOLUME_ID'] | [0].\"lifecycle-state\"" --raw-output 2>/dev/null || true)

if [[ "$ATTACHMENT_STATE" != "ATTACHED" ]]; then
  echo "    attaching volume to instance (paravirtualized)"
  oci compute volume-attachment attach \
    --instance-id "$INSTANCE_ID" \
    --volume-id "$VOLUME_ID" \
    --type paravirtualized \
    --display-name "${DATA_VOLUME_NAME}-attachment" \
    --wait-for-state ATTACHED >/dev/null
else
  echo "    already attached"
fi
echo "    ok"

echo "==> Block storage: formatting (if needed) and mounting at $DATA_MOUNT_POINT"
ssh_run "
  set -e
  DEV=\$(readlink -f /dev/oracleoci/oraclevda 2>/dev/null || true)
  # If oraclevda doesn't exist (e.g. disk naming differs), fall back to the first disk
  # that isn't the boot disk (sda).
  if [[ -z \"\$DEV\" || ! -b \"\$DEV\" ]]; then
    DEV=\$(lsblk -ndo NAME,TYPE | awk '\$2==\"disk\" && \$1!=\"sda\" {print \"/dev/\"\$1; exit}')
  fi
  if ! sudo blkid \"\$DEV\" >/dev/null 2>&1; then
    echo \"    formatting \$DEV as ext4\"
    sudo mkfs.ext4 -L data \"\$DEV\"
  else
    echo \"    \$DEV already has a filesystem, skipping mkfs\"
  fi
  sudo mkdir -p $DATA_MOUNT_POINT
  UUID=\$(sudo blkid -s UUID -o value \"\$DEV\")
  grep -q \"\$UUID\" /etc/fstab || echo \"UUID=\$UUID $DATA_MOUNT_POINT ext4 defaults,nofail 0 2\" | sudo tee -a /etc/fstab >/dev/null
  sudo mount -a
  df -h $DATA_MOUNT_POINT
"
echo "    ok"

echo "==> Done. VM_IP=$VM_IP. Log out/in (or start a new SSH session) for the docker group to take effect."
