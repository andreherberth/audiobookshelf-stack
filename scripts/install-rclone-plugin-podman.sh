#!/usr/bin/env bash
set -euo pipefail

# Set up rclone serve docker as a systemd service for Podman volume plugin support.
# Docker's managed plugin (docker plugin install) does not work on Podman.
# See: https://rclone.org/docker/

if ! command -v rclone &>/dev/null; then
  echo "rclone is not installed. Install it first:" >&2
  echo "  https://rclone.org/install/" >&2
  exit 1
fi

CONFIG_DIR="/var/lib/docker-plugins/rclone/config"
CACHE_DIR="/var/lib/docker-plugins/rclone/cache"
BASE_DIR="/var/lib/docker-volumes/rclone"
SOCKET_PATH="/run/docker/plugins/rclone.sock"

echo "Creating directories..."
sudo mkdir -p "${CONFIG_DIR}" "${CACHE_DIR}" "${BASE_DIR}"
sudo mkdir -p "$(dirname "${SOCKET_PATH}")"

if [[ ! -f "${CONFIG_DIR}/rclone.conf" ]]; then
  echo "Warning: ${CONFIG_DIR}/rclone.conf not found."
  echo "Copy and edit the example config:"
  echo "  sudo cp rclone/rclone.conf.example ${CONFIG_DIR}/rclone.conf"
  echo "  sudo \$EDITOR ${CONFIG_DIR}/rclone.conf"
fi

SERVICE_FILE="/etc/systemd/system/docker-volume-rclone.service"
SOCKET_FILE="/etc/systemd/system/docker-volume-rclone.socket"

echo "Installing systemd unit files..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Rclone Docker Volume Plugin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/rclone serve docker \\
  --base-dir ${BASE_DIR} \\
  --socket-addr unix://${SOCKET_PATH} \\
  --config ${CONFIG_DIR}/rclone.conf \\
  --cache-dir ${CACHE_DIR} \\
  --allow-other \\
  -v
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee "${SOCKET_FILE}" > /dev/null <<EOF
[Unit]
Description=Rclone Docker Volume Plugin Socket

[Socket]
ListenStream=${SOCKET_PATH}

[Install]
WantedBy=sockets.target
EOF

echo "Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable docker-volume-rclone.socket
sudo systemctl start docker-volume-rclone.socket
sudo systemctl enable docker-volume-rclone.service
sudo systemctl start docker-volume-rclone.service

CONTAINERS_CONF_DROPIN="/etc/containers/containers.conf.d/99-rclone-volume-plugin.conf"
echo "Configuring Podman volume plugin..."
sudo mkdir -p "$(dirname "${CONTAINERS_CONF_DROPIN}")"
sudo tee "${CONTAINERS_CONF_DROPIN}" > /dev/null <<EOF
[volume_plugins]
  [volume_plugins.rclone]
    socket = "${SOCKET_PATH}"
EOF

echo ""
echo "Done. Verify with:"
echo "  systemctl status docker-volume-rclone.service"
echo "  ls -la ${SOCKET_PATH}"
echo ""
echo "Then start the stack:"
echo "  podman compose -f compose.rclone-plugin.yml up -d"
