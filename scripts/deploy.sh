#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — deploy damsac to VPS via rsync + remote nixos-rebuild
# Dependencies: rsync, ssh
# Usage: deploy.sh [host]
#   host defaults to DAMSAC_VPS_IP env var

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST="${1:-${DAMSAC_VPS_IP:-}}"
SSH_KEY="$PROJECT_DIR/keys/deploy"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [[ -z "$HOST" ]]; then
  echo "error: no host specified" >&2
  echo "usage: deploy.sh <ip>  or  export DAMSAC_VPS_IP=<ip>" >&2
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "error: SSH key not found at $SSH_KEY" >&2
  exit 1
fi

cd "$PROJECT_DIR"

echo "deploying damsac to $HOST..."

# Sync flake to VPS and rebuild remotely
echo "syncing flake to VPS..."
rsync -az --delete \
  --exclude='.git' \
  --exclude='infra/' \
  --exclude='keys/deploy' \
  --exclude='sdk/' \
  --exclude='docs/' \
  --exclude='.claude/' \
  -e "ssh $SSH_OPTS" \
  "$PROJECT_DIR/" "root@${HOST}:/srv/damsac/damsac-studio/"

echo "rebuilding on VPS..."
ssh $SSH_OPTS "root@${HOST}" "cd /srv/damsac/damsac-studio && nixos-rebuild switch --flake .#damsac"

echo ""
echo "deploy complete. verifying..."

# Quick verification
echo ""
ssh $SSH_OPTS "root@${HOST}" "
  state=\$(systemctl is-active damsac-studio 2>/dev/null || echo inactive)
  echo \"service: \$state\"
  test -f /run/secrets/damsac-dashboard-pw && echo 'secrets: present' || echo 'secrets: MISSING'
  ss -tlnp 2>/dev/null | grep -q ':8080 ' && echo 'port 8080: listening' || echo 'port 8080: not listening'
  ss -tlnp 2>/dev/null | grep -q ':80 ' && echo 'port 80: listening (caddy)' || echo 'port 80: not listening'
"

echo ""
echo "done. run 'damsac-status' for full health check."
