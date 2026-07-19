#!/usr/bin/env bash
set -euo pipefail

# Install the rclone Docker volume plugin (Docker Engine only).
# See: https://rclone.org/docker/

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  PLUGIN_TAG="amd64" ;;
  aarch64) PLUGIN_TAG="arm64" ;;
  armv7l)  PLUGIN_TAG="arm-v7" ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

CONFIG_DIR="/var/lib/docker-plugins/rclone/config"
CACHE_DIR="/var/lib/docker-plugins/rclone/cache"

echo "Creating plugin directories..."
sudo mkdir -p "${CONFIG_DIR}" "${CACHE_DIR}"

if [[ ! -f "${CONFIG_DIR}/rclone.conf" ]]; then
  echo "Warning: ${CONFIG_DIR}/rclone.conf not found."
  echo "Copy rclone/rclone.conf.example and fill in your Hetzner credentials:"
  echo "  sudo cp rclone/rclone.conf.example ${CONFIG_DIR}/rclone.conf"
  echo "  sudo \$EDITOR ${CONFIG_DIR}/rclone.conf"
fi

if docker plugin inspect rclone &>/dev/null; then
  echo "rclone plugin already installed."
  docker plugin inspect rclone --format '{{.Id}}'
  exit 0
fi

echo "Installing rclone/docker-volume-rclone:${PLUGIN_TAG}..."
docker plugin install "rclone/docker-volume-rclone:${PLUGIN_TAG}" \
  --alias rclone \
  --grant-all-permissions \
  args="-v --allow-other"

echo "Done. Verify with: docker plugin ls"
