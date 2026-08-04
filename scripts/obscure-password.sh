#!/usr/bin/env bash
# Obscure a Storage Box password for rclone (STORAGEBOX_PASS in .env).
# Usage: ./scripts/obscure-password.sh 'your-password'
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Usage: $0 '<password>'" >&2
  exit 1
fi

if command -v rclone >/dev/null 2>&1; then
  rclone obscure "$1"
else
  docker run --rm rclone/rclone:latest obscure "$1"
fi
