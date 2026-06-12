#!/usr/bin/env bash
# Rewrite gfc-mosdns.service to use easymosdns config path (not legacy mosdns.yaml)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

CFG="/etc/gfc-client/mosdns/config.yaml"
if [[ ! -f "$CFG" ]]; then
  echo "WARN: $CFG missing — run repair-dns.sh first"
fi

cat >/etc/systemd/system/gfc-mosdns.service <<EOF
[Unit]
Description=GFC Client mosdns (easymosdns)
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/gfc-client/mosdns
ExecStart=/usr/local/bin/mosdns start -c ${CFG}
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/mosdns.log
StandardError=append:/var/log/gfc-client/mosdns.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gfc-mosdns
systemctl restart gfc-mosdns
sleep 1
systemctl is-active gfc-mosdns
ss -lntup | grep 5335 || true
echo "gfc-mosdns unit fixed."
