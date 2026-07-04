#!/usr/bin/env bash
# Shared helper to lock the VM's web ports (80/443) to Cloudflare's origin IP
# ranges. Source this file, don't execute it directly.
#
# Expects the caller to have already defined an `ssh_run` function that runs
# its arguments on the VM (every script in oci-infra/ and ssh/ defines one),
# and to pass the path to oci-infra/cf-lock-iptables.sh. It installs that
# script on the VM plus a weekly systemd timer that reruns it, then applies it
# once. See cf-lock-iptables.sh for what the rules actually do and why.

apply_cloudflare_lock() {
  local vm_script="$1"
  [[ -f "$vm_script" ]] || { echo "apply_cloudflare_lock: script not found: $vm_script" >&2; return 1; }

  echo "==> Firewall: locking 80/443 to Cloudflare origin ranges (+ weekly refresh timer)"

  # `netfilter-persistent save` (called by the VM script) needs this package.
  ssh_run 'command -v netfilter-persistent >/dev/null 2>&1 || { sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netfilter-persistent iptables-persistent >/dev/null; }'

  # Install the refresh script (piped up over SSH; ssh_run forwards stdin).
  ssh_run 'sudo tee /usr/local/sbin/cf-lock-iptables.sh >/dev/null && sudo chmod 755 /usr/local/sbin/cf-lock-iptables.sh' < "$vm_script"

  # Oneshot + weekly timer so the allowlist tracks Cloudflare's ranges.
  ssh_run 'sudo tee /etc/systemd/system/cf-lock-iptables.service >/dev/null' <<'UNIT'
[Unit]
Description=Restrict inbound HTTP/HTTPS to Cloudflare origin IP ranges
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cf-lock-iptables.sh
UNIT

  ssh_run 'sudo tee /etc/systemd/system/cf-lock-iptables.timer >/dev/null' <<'UNIT'
[Unit]
Description=Weekly refresh of the Cloudflare IP allowlist
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
UNIT

  ssh_run 'sudo systemctl daemon-reload && sudo systemctl enable --now cf-lock-iptables.timer && sudo /usr/local/sbin/cf-lock-iptables.sh'
  echo "    ok"
}
