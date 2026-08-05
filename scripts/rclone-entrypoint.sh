#!/bin/sh
# Coolify/rclone FUSE mount helper.
# - Obscures a plain STORAGEBOX_PASS for rclone env config
# - Then execs rclone with the given args (usually: mount ...)
set -eu

if [ -n "${STORAGEBOX_PASS:-}" ]; then
  export RCLONE_CONFIG_HETZNER_PASS
  RCLONE_CONFIG_HETZNER_PASS="$(rclone obscure "$STORAGEBOX_PASS")"
fi

echo "rclone-entrypoint: starting: rclone $*"
exec rclone "$@"
