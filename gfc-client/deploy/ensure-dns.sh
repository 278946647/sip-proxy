#!/usr/bin/env bash
# Layer 4 — DNS prep only (run immediately before gfc-mosdns). Does not start MosDNS.
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
MOSDNS_PORT="${GFC_MOSDNS_PORT:-53}"

echo "==> ensure-dns"

# 4a. Stub resolver must be off before MosDNS binds :53
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  echo "    stop systemd-resolved..."
  systemctl disable --now systemd-resolved 2>/dev/null || systemctl stop systemd-resolved 2>/dev/null || true
fi
if [[ -L /etc/resolv.conf ]]; then
  rm -f /etc/resolv.conf
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
cat >/etc/resolv.conf <<'EOF'
nameserver 127.0.0.1
EOF
chmod 644 /etc/resolv.conf
echo "    resolv.conf -> 127.0.0.1"

# 4b. Config must listen on :53 (bootstrap should have rendered this)
CFG="${GFC_ETC}/mosdns/easymosdns/config.yaml"
if [[ -f "$CFG" ]] && ! grep -q "0.0.0.0:${MOSDNS_PORT}\"" "$CFG"; then
  echo "    WARN: mosdns config not on :${MOSDNS_PORT} — run gfc-bootstrap or fix config"
fi

# 4c. Port conflict check
if command -v ss >/dev/null; then
  echo "    listeners on udp/53:"
  ss -ulnp | grep ':53 ' || echo "      (none)"
fi

echo "==> ensure-dns done"
