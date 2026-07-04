#!/usr/bin/env bash
# Restrict inbound HTTP/HTTPS (80/443) to Cloudflare's published origin IP
# ranges only. Runs ON THE VM (installed at /usr/local/sbin/cf-lock-iptables.sh
# by lib/firewall.sh). Idempotent and safe to re-run — a systemd timer
# reruns it weekly so the allowlist tracks Cloudflare's ranges as they change.
#
# The VM sits behind Cloudflare (foyeriq.in / pgadmin.foyeriq.in are proxied),
# so all legitimate web traffic arrives from Cloudflare's edge. Locking the
# web ports to those ranges stops anyone from bypassing Cloudflare's
# WAF/rate-limiting/DDoS protection by hitting the origin IP directly.
#
#   - SSH (22) is deliberately NOT touched — no lockout, recovery always possible.
#   - The Postgres wire protocol on 443 is no longer reachable directly (Cloudflare
#     can't proxy it); use an SSH tunnel instead:
#       ssh -L 5432:127.0.0.1:5432 ubuntu@<vm>   # then psql host=127.0.0.1 port=5432
#   - The old per-source-IP hashlimit on 443 is removed: behind Cloudflare the
#     "source IP" is a shared Cloudflare edge, so per-IP limits throttle real
#     users. Rate-limiting belongs at Cloudflare now.
#
# There is no global IPv6 on this host (nginx only listens on 0.0.0.0:443), so
# only iptables (IPv4) is managed. If IPv6 is ever enabled, this must be
# extended to ip6tables with Cloudflare's IPv6 ranges (www.cloudflare.com/ips-v6).
set -euo pipefail

CHAIN="CF_ALLOW"
WEB_PORTS="80,443"
CF_IPS_URL="https://www.cloudflare.com/ips-v4"

# Fetch and sanity-check Cloudflare's ranges BEFORE touching the firewall, so a
# failed/garbled download never leaves the origin half-open or fully closed.
CF_IPS="$(curl -fsS --retry 3 --max-time 20 "$CF_IPS_URL")"
if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' <<<"$CF_IPS"; then
  echo "cf-lock: refusing to apply — '$CF_IPS_URL' did not return valid CIDRs" >&2
  exit 1
fi

# (Re)build the allowlist chain from scratch each run.
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
while IFS= read -r cidr; do
  [ -n "$cidr" ] || continue
  iptables -A "$CHAIN" -s "$cidr" -j ACCEPT
done <<<"$CF_IPS"
# Anything that reached this chain (i.e. a NEW connection to 80/443) but isn't
# from Cloudflare gets dropped silently — no RST, so the origin stays invisible.
iptables -A "$CHAIN" -j DROP

# Send NEW connections to the web ports through the allowlist. Insert first, and
# only if not already present, so re-runs don't stack duplicate jumps. Adding
# the jump BEFORE deleting the old world-open rules means there is never a
# window where Cloudflare traffic is blocked.
if ! iptables -C INPUT -p tcp -m multiport --dports "$WEB_PORTS" -m conntrack --ctstate NEW -j "$CHAIN" 2>/dev/null; then
  iptables -I INPUT 1 -p tcp -m multiport --dports "$WEB_PORTS" -m conntrack --ctstate NEW -j "$CHAIN"
fi

# Remove the legacy world-open ACCEPTs and the per-IP hashlimit from earlier
# setups, if present (harmless no-ops otherwise).
iptables -D INPUT -p tcp -m tcp --dport 80  -m state --state NEW -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp -m tcp --dport 443 -m state --state NEW -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp -m tcp --dport 443 -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-above 20/min --hashlimit-burst 30 --hashlimit-mode srcip \
  --hashlimit-name conn443 -j DROP 2>/dev/null || true

netfilter-persistent save >/dev/null
echo "cf-lock: allowlisted $(grep -c . <<<"$CF_IPS") Cloudflare range(s) on ports ${WEB_PORTS}; 22 left open."
