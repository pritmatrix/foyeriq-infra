#!/usr/bin/env bash
# get-arm-vm.sh — Oracle Cloud Free Tier Ampere A1 provisioner.
#
# Idempotent script that gets you a 4 OCPU / 24 GB / Ubuntu 22.04 ARM VM with
# a public reserved IP, ready to SSH into. Always Free Tier — no card charge.
#
# What it does, in order:
#   1. Verifies OCI CLI is installed + authenticated
#   2. Generates an SSH keypair if one doesn't exist
#   3. Ensures a VCN exists  (creates if missing)
#   4. Ensures a public subnet exists (creates if missing)
#   5. Patches the default security list to allow inbound 80, 443, and SSH
#   6. Ensures a reserved public IP exists (so the VM's IP survives reboot)
#   7. Picks the newest Ubuntu 22.04 ARM image
#   8. Launches the A1 instance, retrying through "out of capacity" errors
#   9. Associates the reserved IP with the instance's primary VNIC
#  10. Prints the public IP + ready-to-paste SSH command
#
# Re-running is SAFE. Every step detects existing state and skips. If a
# previous run died partway through (network blip, capacity error, timeout),
# just run again — it'll pick up where it left off.
#
# ── Configuration (override via env vars) ─────────────────────────────────
#   VM_NAME=arm-vm            display name for the instance + related resources
#   VCN_NAME=$VM_NAME-vcn
#   RESERVED_IP_NAME=$VM_NAME-ip
#   SSH_KEY=~/.ssh/oci-arm    path to private key; .pub is uploaded to OCI
#   OCPUS=4                   max for Always Free is 4
#   MEMORY_GB=24              max for Always Free is 24
#   BOOT_VOL_GB=50            default 47, max 200 (Always Free total: 200 GB)
#   COMPARTMENT_ID=           defaults to your tenancy (i.e. root compartment)
#   CLOUD_INIT_FILE=./cloud-init.yaml   first-boot config (sibling file)
#   CAPACITY_RETRIES=20       attempts inside this one invocation
#   CAPACITY_INTERVAL=90      seconds between attempts
#
# ── Usage ─────────────────────────────────────────────────────────────────
#   chmod +x get-arm-vm.sh
#   ./get-arm-vm.sh
#
# A1 capacity is supply-constrained in some regions (Mumbai/Hyderabad/Tokyo
# get locked for days). If the in-script retries (default 30 minutes) aren't
# enough, run it under cron until an attempt finally lands — see README.md
# section "If A1 capacity is locked".
#
# ── Tear-down ─────────────────────────────────────────────────────────────
# Console: Compute → Instances → ... → Terminate. Also terminate the boot
# volume to free the storage quota. Then Networking → Reserved Public IPs
# and detach the reserved IP if you no longer need it.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────
VM_NAME="${VM_NAME:-arm-vm}"
VCN_NAME="${VCN_NAME:-${VM_NAME}-vcn}"
SUBNET_NAME="${SUBNET_NAME:-${VM_NAME}-public-subnet}"
RESERVED_IP_NAME="${RESERVED_IP_NAME:-${VM_NAME}-ip}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oci-arm}"
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_VOL_GB="${BOOT_VOL_GB:-50}"
CAPACITY_RETRIES="${CAPACITY_RETRIES:-20}"
CAPACITY_INTERVAL="${CAPACITY_INTERVAL:-90}"
CLOUD_INIT_FILE="${CLOUD_INIT_FILE:-$(dirname "$0")/cloud-init.yaml}"

# ─── Helpers ──────────────────────────────────────────────────────────────
step() { printf '\033[1;36m[step]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  warn\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  fail\033[0m %s\n' "$*" >&2; exit 1; }

# OCI CLI prints a bunch of deprecation/security warnings to stderr that
# confuse JSON parsing. Strip them.
export SUPPRESS_LABEL_WARNING=True
oci_q() { oci "$@" 2>&1 | grep -v -E "FutureWarning|SyntaxWarning|warnings\.warn|invalid escape sequence|WARNING: This operation supports pagination"; }

# ─── 1. Preflight ─────────────────────────────────────────────────────────
step "Preflight: OCI CLI + auth + cloud-init"
command -v oci >/dev/null 2>&1 || fail "oci CLI not found. See README.md \"Install OCI CLI\"."
oci_q iam region list --query 'data[0].name' --raw-output >/dev/null 2>&1 \
  || fail "OCI CLI not authenticated. Run: oci setup config"
[[ -f "$CLOUD_INIT_FILE" ]] || fail "cloud-init file not found at: $CLOUD_INIT_FILE"

TENANCY="${COMPARTMENT_ID:-$(oci_q iam compartment list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)}"
[[ -n "$TENANCY" && "$TENANCY" != "null" ]] || fail "could not resolve tenancy/compartment OCID. Set COMPARTMENT_ID, or check `~/.oci/config`."
REGION=$(oci_q iam region-subscription list --query 'data[?"is-home-region"==`true`]."region-name" | [0]' --raw-output)
ok "tenancy/compartment: $TENANCY"
ok "home region: $REGION"

# ─── 2. SSH key ───────────────────────────────────────────────────────────
step "SSH key at $SSH_KEY"
if [[ ! -f "$SSH_KEY" ]]; then
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "$VM_NAME"
  ok "generated new keypair"
else
  ok "exists"
fi
[[ -f "$SSH_KEY.pub" ]] || fail "private key found but $SSH_KEY.pub is missing"

# ─── 3. VCN ───────────────────────────────────────────────────────────────
step "VCN '$VCN_NAME'"
VCN_ID=$(oci_q network vcn list --compartment-id "$TENANCY" --display-name "$VCN_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)
if [[ -z "$VCN_ID" || "$VCN_ID" == "null" ]]; then
  VCN_ID=$(oci_q network vcn create --compartment-id "$TENANCY" \
    --display-name "$VCN_NAME" --cidr-block "10.0.0.0/16" --dns-label "$(echo "$VM_NAME" | tr -dc '[:alnum:]' | cut -c1-15)" \
    --query 'data.id' --raw-output)
  ok "created: $VCN_ID"
else
  ok "exists: $VCN_ID"
fi

step "Internet Gateway"
IGW_ID=$(oci_q network internet-gateway list --compartment-id "$TENANCY" --vcn-id "$VCN_ID" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)
if [[ -z "$IGW_ID" || "$IGW_ID" == "null" ]]; then
  IGW_ID=$(oci_q network internet-gateway create --compartment-id "$TENANCY" --vcn-id "$VCN_ID" \
    --display-name "${VM_NAME}-igw" --is-enabled true --query 'data.id' --raw-output)
  ok "created"
else
  ok "exists"
fi

step "Default route table → IGW"
RT_ID=$(oci_q network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)
HAS_ROUTE=$(oci_q network route-table get --rt-id "$RT_ID" \
  --query "data.\"route-rules\"[?\"network-entity-id\"=='$IGW_ID'] | length(@)" --raw-output 2>/dev/null || echo 0)
if [[ "$HAS_ROUTE" -eq 0 ]]; then
  oci_q network route-table update --rt-id "$RT_ID" --force \
    --route-rules "[{\"destination\": \"0.0.0.0/0\", \"destinationType\": \"CIDR_BLOCK\", \"networkEntityId\": \"$IGW_ID\"}]" >/dev/null
  ok "added 0.0.0.0/0 → IGW"
else
  ok "already routed"
fi

# ─── 4. Subnet ────────────────────────────────────────────────────────────
step "Public subnet '$SUBNET_NAME'"
SUBNET_ID=$(oci_q network subnet list --compartment-id "$TENANCY" --vcn-id "$VCN_ID" --display-name "$SUBNET_NAME" \
  --query 'data[0].id' --raw-output 2>/dev/null || true)
if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
  SUBNET_ID=$(oci_q network subnet create --compartment-id "$TENANCY" --vcn-id "$VCN_ID" \
    --display-name "$SUBNET_NAME" --cidr-block "10.0.0.0/24" \
    --route-table-id "$RT_ID" \
    --query 'data.id' --raw-output)
  ok "created: $SUBNET_ID"
else
  ok "exists: $SUBNET_ID"
fi

# ─── 5. Security list: allow 22, 80, 443 inbound ──────────────────────────
step "Security list ingress rules (22, 80, 443)"
SL_ID=$(oci_q network vcn get --vcn-id "$VCN_ID" --query 'data."default-security-list-id"' --raw-output)
EXISTING_RULES=$(oci_q network security-list get --security-list-id "$SL_ID" --query 'data."ingress-security-rules"' --output json 2>/dev/null)
NEED_UPDATE=0
for PORT in 22 80 443; do
  HAS=$(echo "$EXISTING_RULES" | jq --arg p "$PORT" '[.[] | select(."tcp-options"."destination-port-range".min == ($p|tonumber))] | length')
  if [[ "$HAS" -eq 0 ]]; then NEED_UPDATE=1; fi
done

if [[ "$NEED_UPDATE" -eq 1 ]]; then
  MERGED=$(echo "$EXISTING_RULES" | jq '
    . + [
      {"source": "0.0.0.0/0", "protocol": "6", "isStateless": false, "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}}},
      {"source": "0.0.0.0/0", "protocol": "6", "isStateless": false, "tcpOptions": {"destinationPortRange": {"min": 80, "max": 80}}},
      {"source": "0.0.0.0/0", "protocol": "6", "isStateless": false, "tcpOptions": {"destinationPortRange": {"min": 443, "max": 443}}}
    ] | unique_by(."tcp-options"."destination-port-range".min // (.tcpOptions.destinationPortRange.min))
  ')
  oci_q network security-list update --security-list-id "$SL_ID" --force --ingress-security-rules "$MERGED" >/dev/null
  ok "rules added/merged"
else
  ok "all three already allowed"
fi

# ─── 6. Reserved public IP ────────────────────────────────────────────────
step "Reserved public IP '$RESERVED_IP_NAME'"
PUBLIC_IP_ID=$(oci_q network public-ip list --compartment-id "$TENANCY" --scope REGION \
  --query "data[?\"display-name\"=='$RESERVED_IP_NAME'] | [0].id" --raw-output 2>/dev/null || true)
if [[ -z "$PUBLIC_IP_ID" || "$PUBLIC_IP_ID" == "null" ]]; then
  PUBLIC_IP_ID=$(oci_q network public-ip create --compartment-id "$TENANCY" \
    --lifetime RESERVED --display-name "$RESERVED_IP_NAME" \
    --query 'data.id' --raw-output)
  ok "reserved: $PUBLIC_IP_ID"
else
  ok "exists: $PUBLIC_IP_ID"
fi
PUBLIC_IP_ADDR=$(oci_q network public-ip get --public-ip-id "$PUBLIC_IP_ID" --query 'data."ip-address"' --raw-output)
ok "IP address: $PUBLIC_IP_ADDR"

# ─── 7. Availability domain + Ubuntu 22.04 ARM image ──────────────────────
step "Availability domain"
AD=$(oci_q iam availability-domain list --compartment-id "$TENANCY" --query 'data[0].name' --raw-output)
ok "$AD"

step "Newest Ubuntu 22.04 aarch64 image"
IMAGE_ID=$(oci_q compute image list --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)
ok "$IMAGE_ID"

# ─── 8. Instance launch (with capacity retry) ─────────────────────────────
step "Instance '$VM_NAME'"
INSTANCE_ID=$(oci_q compute instance list --compartment-id "$TENANCY" \
  --display-name "$VM_NAME" \
  --query "data[?\"lifecycle-state\" != 'TERMINATED' && \"lifecycle-state\" != 'TERMINATING'] | [0].id" \
  --raw-output 2>/dev/null || true)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
  step "Launching A1 (${OCPUS} OCPU / ${MEMORY_GB} GB / ${BOOT_VOL_GB} GB boot)"
  # --assign-public-ip true — needed so cloud-init has internet on first boot
  # to install apt packages and Docker. The reserved-IP association below
  # REPLACES the ephemeral IP once the instance is RUNNING.
  #
  # Dedup pre-check: when the OCI API times out (~2 min waits), the launch
  # often succeeded server-side but the client never got the OCID back.
  # Blind retries create duplicate instances + trip the A1 service limit.
  # Before each attempt, re-list to adopt any in-flight launch from a
  # previous run/iteration.
  for i in $(seq 1 "$CAPACITY_RETRIES"); do
    EXISTING=$(oci_q compute instance list --compartment-id "$TENANCY" \
      --display-name "$VM_NAME" \
      --query "data[?\"lifecycle-state\" != 'TERMINATED' && \"lifecycle-state\" != 'TERMINATING'] | [0].id" \
      --raw-output 2>/dev/null || true)
    if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
      INSTANCE_ID="$EXISTING"
      ok "adopted in-flight instance: $INSTANCE_ID"
      break
    fi

    printf '  attempt %d/%d ... ' "$i" "$CAPACITY_RETRIES"
    OUT=$(oci compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$TENANCY" \
      --shape "VM.Standard.A1.Flex" \
      --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --display-name "$VM_NAME" \
      --ssh-authorized-keys-file "$SSH_KEY.pub" \
      --user-data-file "$CLOUD_INIT_FILE" \
      --boot-volume-size-in-gbs "$BOOT_VOL_GB" \
      --no-retry \
      --query 'data.id' --raw-output 2>&1) || true
    if echo "$OUT" | head -1 | grep -q "^ocid1.instance"; then
      INSTANCE_ID=$(echo "$OUT" | head -1)
      ok "launched: $INSTANCE_ID"
      break
    fi
    if echo "$OUT" | grep -qE "Out of host capacity|TooManyRequests|Too many requests|\"status\": 500"; then
      echo "out of capacity (or capacity-lock disguised as rate-limit/500), sleeping ${CAPACITY_INTERVAL}s"
      sleep "$CAPACITY_INTERVAL"
    elif echo "$OUT" | grep -qE "timed out|service limits were exceeded"; then
      echo "timeout/quota — re-checking instance list on next loop"
      sleep 10
    else
      echo "ERROR"
      echo "$OUT" | head -10
      fail "instance launch failed (non-recoverable error)"
    fi
  done
  [[ -z "${INSTANCE_ID:-}" ]] && fail "exhausted retries — capacity still locked. See README.md \"If A1 capacity is locked\"."
else
  ok "already exists: $INSTANCE_ID"
fi

# ─── 9. Wait for RUNNING + associate reserved IP ──────────────────────────
step "Waiting for instance to be RUNNING"
for i in {1..60}; do
  STATE=$(oci_q compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output)
  if [[ "$STATE" == "RUNNING" ]]; then break; fi
  printf '  state=%s (waiting...)\r' "$STATE"
  sleep 5
done
[[ "$STATE" == "RUNNING" ]] || fail "instance did not reach RUNNING (last state: $STATE)"
echo ""
ok "RUNNING"

step "Associating reserved IP $PUBLIC_IP_ADDR with primary VNIC"
PRIMARY_VNIC_ID=$(oci_q compute instance list-vnics --instance-id "$INSTANCE_ID" --query 'data[0].id' --raw-output)
PRIVATE_IP_ID=$(oci_q network private-ip list --vnic-id "$PRIMARY_VNIC_ID" --query 'data[0].id' --raw-output)

# Detach whatever ephemeral IP is on the VNIC, then attach reserved IP.
CURRENT_PUBLIC_IP_ID=$(oci_q network public-ip get --private-ip-id "$PRIVATE_IP_ID" --query 'data.id' --raw-output 2>/dev/null || true)
if [[ -n "$CURRENT_PUBLIC_IP_ID" && "$CURRENT_PUBLIC_IP_ID" != "null" && "$CURRENT_PUBLIC_IP_ID" != "$PUBLIC_IP_ID" ]]; then
  CURRENT_LIFETIME=$(oci_q network public-ip get --public-ip-id "$CURRENT_PUBLIC_IP_ID" --query 'data.lifetime' --raw-output)
  if [[ "$CURRENT_LIFETIME" == "EPHEMERAL" ]]; then
    oci_q network public-ip delete --public-ip-id "$CURRENT_PUBLIC_IP_ID" --force >/dev/null
    ok "released ephemeral public IP"
    sleep 3
  fi
fi

ALREADY=$(oci_q network public-ip get --public-ip-id "$PUBLIC_IP_ID" --query 'data."private-ip-id"' --raw-output 2>/dev/null || true)
if [[ "$ALREADY" != "$PRIVATE_IP_ID" ]]; then
  oci_q network public-ip update --public-ip-id "$PUBLIC_IP_ID" --private-ip-id "$PRIVATE_IP_ID" >/dev/null
  ok "reserved IP attached"
else
  ok "reserved IP already attached"
fi

# ─── 10. Print connection info ────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Done. Your VM is up."
echo "============================================================"
echo "  Region:   $REGION"
echo "  Name:     $VM_NAME"
echo "  Public IP: $PUBLIC_IP_ADDR"
echo "  SSH key:  $SSH_KEY"
echo ""
echo "  Wait ~60–90 s for cloud-init (Docker install) to finish, then:"
echo ""
echo "    ssh -i $SSH_KEY ubuntu@$PUBLIC_IP_ADDR"
echo ""
echo "  Verify first-boot config completed:"
echo ""
echo "    ssh -i $SSH_KEY ubuntu@$PUBLIC_IP_ADDR 'ls -l /var/log/cloud-init-done && docker --version'"
echo "============================================================"
