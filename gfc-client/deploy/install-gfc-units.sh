#!/usr/bin/env bash
# Install / refresh gfc systemd units (safe to re-run on upgrade).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_SINGBOX_USER="${GFC_SINGBOX_USER:-singbox}"

cat >/etc/systemd/system/gfc-sing-box.service <<EOF
[Unit]
Description=GFC Sing-box TUN (gfctun outbound engine)
After=gfc-mosdns.service
Wants=gfc-mosdns.service
Before=gfc-routing.service

[Service]
Type=simple
User=${GFC_SINGBOX_USER}
Group=${GFC_SINGBOX_USER}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
PrivateDevices=no
ExecCondition=/bin/grep -q '"type": "tun"' /etc/gfc-client/sing-box.json
# '+' = run as root even though User=singbox (nft/ip/chown need root; gfc.env is 600).
ExecStartPre=+/bin/bash ${GFC_ROOT}/deploy/singbox-nft-cleanup.sh
ExecStartPre=+/bin/bash -c 'chown root:${GFC_SINGBOX_USER} /etc/gfc-client/sing-box.json 2>/dev/null; chmod 640 /etc/gfc-client/sing-box.json 2>/dev/null; touch /var/log/gfc-client/sing-box.log; chown ${GFC_SINGBOX_USER}:${GFC_SINGBOX_USER} /var/log/gfc-client/sing-box.log'
ExecStart=/usr/local/bin/sing-box run -c /etc/gfc-client/sing-box.json
ExecStartPost=+/bin/bash ${GFC_ROOT}/deploy/gfc-routing.sh start
ExecStopPost=+/bin/bash -c '${GFC_ROOT}/deploy/singbox-nft-cleanup.sh; ${GFC_ROOT}/deploy/gfc-routing.sh stop || true'
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/gfc-client/sing-box.log
StandardError=append:/var/log/gfc-client/sing-box.log

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gfc-routing.service <<EOF
[Unit]
Description=GFC Kernel Policy Routing (fwmark → gfctun)
After=gfc-sing-box.service
Wants=gfc-sing-box.service
Before=gfc-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=60
EnvironmentFile=/etc/gfc-client/gfc.env
ExecCondition=/bin/grep -q '"type": "tun"' /etc/gfc-client/sing-box.json
ExecStartPre=/bin/bash ${GFC_ROOT}/deploy/singbox-nft-cleanup.sh
ExecStart=/bin/bash ${GFC_ROOT}/deploy/gfc-routing.sh start
ExecStop=/bin/bash ${GFC_ROOT}/deploy/gfc-routing.sh stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gfc-routing.service 2>/dev/null || true
echo "==> gfc units refreshed (gfc-sing-box, gfc-routing)"
