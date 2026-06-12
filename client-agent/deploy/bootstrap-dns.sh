#!/usr/bin/env bash
# Emergency DNS: stop proxy hijack, point resolver at public DNS (for git pull / activate).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

PUBLIC_DNS=(223.5.5.5 119.29.29.29 8.8.8.8)

echo "==> Stop DNS hijackers (sing-box / mosdns / agent)"
for u in gfc-client-sing-box gfc-mosdns gfc-client-agent; do
  systemctl stop "$u" 2>/dev/null || true
done
ip link del gfc0 2>/dev/null || true

if systemctl is-active systemd-resolved &>/dev/null; then
  echo "==> systemd-resolved bootstrap"
  mkdir -p /etc/systemd/resolved.conf.d
  cat >/etc/systemd/resolved.conf.d/gfc-bootstrap.conf <<'EOF'
[Resolve]
DNS=223.5.5.5 119.29.29.29
FallbackDNS=8.8.8.8 1.1.1.1
DNSStubListener=no
EOF
  systemctl restart systemd-resolved
fi

echo "==> /etc/resolv.conf -> public DNS"
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
{
  for ns in "${PUBLIC_DNS[@]}"; do
    echo "nameserver $ns"
  done
} >/etc/resolv.conf
chmod 644 /etc/resolv.conf

echo "==> dnsmasq emergency upstream (LAN clients)"
DNSMASQ_GFC=/etc/dnsmasq.d/gfc-client.conf
if [[ -f "$DNSMASQ_GFC" ]] && ! grep -q gfc-bootstrap /etc/dnsmasq.d/gfc-client-bootstrap.conf 2>/dev/null; then
  cat >/etc/dnsmasq.d/gfc-client-bootstrap.conf <<'EOF'
# GFC emergency — public DNS until mosdns is healthy
server=223.5.5.5
server=8.8.8.8
no-resolv
EOF
  systemctl restart dnsmasq 2>/dev/null || true
fi

echo "==> Test DNS"
ok=0
for host in github.com raw.githubusercontent.com; do
  if getent hosts "$host" >/dev/null 2>&1; then
    echo "    OK  $host"
    ok=1
    break
  fi
  if curl -fsS --connect-timeout 5 --dns-servers 223.5.5.5 "https://$host" -o /dev/null 2>/dev/null; then
    echo "    OK  $host (curl)"
    ok=1
    break
  fi
done

if [[ "$ok" -eq 0 ]]; then
  echo "    WARN: still cannot resolve — check WAN (ping 223.5.5.5)"
  ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 || {
    echo "    ERROR: no route to internet"
    exit 1
  }
  echo "    WAN reachable; DNS may be blocked upstream — continue anyway"
fi

echo "Bootstrap DNS done."
