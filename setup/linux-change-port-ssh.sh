#!/usr/bin/env bash
set -euo pipefail

PORT=8282
CONF=/etc/ssh/sshd_config.d/10-port.conf

sudo tee "$CONF" >/dev/null <<EOF
Port 22
Port ${PORT}
EOF

# SELinux (AL2023/RHEL)
if command -v getenforce >/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
  sudo dnf install -y -q policycoreutils-python-utils
  sudo semanage port -a -t ssh_port_t -p tcp "$PORT" 2>/dev/null \
    || sudo semanage port -m -t ssh_port_t -p tcp "$PORT"
fi

# ufw (Ubuntu)
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow "${PORT}/tcp"
fi

# Kiểm tra config, lỗi thì rollback
sudo mkdir -p /run/sshd
if ! sudo sshd -t; then
  echo "sshd config lỗi -> rollback" >&2
  sudo rm -f "$CONF"
  exit 1
fi

# Restart: Ubuntu socket activation / service ssh / service sshd
if systemctl is-active --quiet ssh.socket; then
  sudo systemctl daemon-reload
  sudo systemctl restart ssh.socket
elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  sudo systemctl restart ssh
else
  sudo systemctl restart sshd
fi

sudo ss -tlnp | grep -E ":(22|${PORT})\b"
