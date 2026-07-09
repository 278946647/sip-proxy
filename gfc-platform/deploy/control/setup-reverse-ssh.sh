#!/usr/bin/env bash
# Prepare host sshd for client autossh reverse tunnels (gfc-reverse user).
#
# Usage (root):
#   sudo bash deploy/control/setup-reverse-ssh.sh
set -euo pipefail

AUTH_KEYS="/var/lib/gfc/reverse-ssh/authorized_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-gfc-reverse.conf"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行: sudo bash $0"
  exit 1
fi

echo "==> GFC reverse SSH host setup"

if ! id gfc-reverse &>/dev/null; then
  useradd -m -s /usr/sbin/nologin gfc-reverse
  echo "    created user gfc-reverse"
else
  echo "    user gfc-reverse exists"
fi

mkdir -p /var/lib/gfc/reverse-ssh
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown root:root "$AUTH_KEYS"

cat >"$SSHD_DROPIN" <<EOF
# GFC client autossh reverse tunnels (managed by control-plane API)
Match User gfc-reverse
    AllowTcpForwarding remote
    PermitTTY no
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile ${AUTH_KEYS}
EOF
chmod 644 "$SSHD_DROPIN"

if sshd -t 2>/dev/null; then
  systemctl reload ssh || systemctl reload sshd || service ssh reload
  echo "    sshd reloaded"
else
  echo "WARN: sshd -t failed; fix config before reload"
  sshd -t || true
fi

echo ""
echo "Done. authorized_keys: ${AUTH_KEYS}"
echo "Ensure docker-compose bind-mounts this file into API (see docker-compose.yml)."
echo "After devices register keys, verify tunnel on host:"
echo "  ss -lntp | grep -E ':60[0-9]{2}\\s'"
