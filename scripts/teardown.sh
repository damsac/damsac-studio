#!/usr/bin/env bash
set -euo pipefail

# teardown.sh — destroy the damsac Hetzner VPS
# Usage: teardown.sh [--delete-key]
#   --delete-key  also delete the SSH key resource from Hetzner

SERVER_NAME="damsac"
SSH_KEY_NAME="damsac-deploy"
DELETE_KEY=false

for arg in "$@"; do
  case "$arg" in
    --delete-key) DELETE_KEY=true ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN is not set"
  exit 1
fi

if ! command -v hcloud &>/dev/null; then
  echo "error: hcloud CLI not found"
  exit 1
fi

# Check if server exists
if ! hcloud server describe "$SERVER_NAME" &>/dev/null; then
  echo "server '$SERVER_NAME' does not exist"
else
  echo "deleting server '$SERVER_NAME'..."
  read -r -p "are you sure? this is irreversible [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "aborted."
    exit 1
  fi
  hcloud server delete "$SERVER_NAME"
  echo "server deleted."
fi

if [ "$DELETE_KEY" = true ]; then
  if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
    echo "deleting SSH key '$SSH_KEY_NAME'..."
    hcloud ssh-key delete "$SSH_KEY_NAME"
    echo "SSH key deleted."
  else
    echo "SSH key '$SSH_KEY_NAME' does not exist"
  fi
fi
