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

# 4b. MosDNS must listen on :53 (not legacy :5335)
CFG="${GFC_ETC}/mosdns/easymosdns/config.yaml"
FIXED=0
if [[ -f "$CFG" ]]; then
  if grep -q '0.0.0.0:5335' "$CFG"; then
    echo "    fix mosdns :5335 -> :${MOSDNS_PORT}"
    sed -i "s/0.0.0.0:5335/0.0.0.0:${MOSDNS_PORT}/g" "$CFG"
    FIXED=1
  fi
  if ! grep -qE "addr: \"0\\.0\\.0\\.0:${MOSDNS_PORT}\"" "$CFG"; then
    if command -v gfc-bootstrap >/dev/null; then
      echo "    render mosdns via gfc-bootstrap..."
      gfc-bootstrap || true
      FIXED=1
    fi
  fi
  if [[ "$FIXED" == "1" ]]; then
    systemctl try-restart gfc-mosdns.service 2>/dev/null || true
    sleep 1
  fi
fi

# 4c. Port conflict check
if command -v ss >/dev/null; then
  echo "    listeners on udp/53:"
  ss -ulnp | grep ':53 ' || echo "      (none)"
fi

echo "==> ensure-dns done"
