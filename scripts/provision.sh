#!/usr/bin/env bash
set -euo pipefail

# provision.sh — create a Hetzner Cloud VPS and install NixOS via nixos-anywhere
#
# Dependencies: hcloud, ssh, jq
# Environment: HCLOUD_TOKEN must be set
#
# Usage: provision.sh [location]
#   location defaults to ash (Ashburn, VA)
#
# Idempotent: if a server named "damsac" already exists, prints the IP and exits.

LOCATION="${1:-ash}"
SERVER_NAME="damsac"
SERVER_TYPE="cpx21"
IMAGE="ubuntu-24.04"
SSH_KEY_NAME="damsac-deploy"
SSH_PUB_KEY="keys/deploy.pub"

# --- Preflight checks ---

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN is not set"
  echo "export it: export \$(cat infra/hetzner.env | xargs)"
  exit 1
fi

if ! command -v hcloud &>/dev/null; then
  echo "error: hcloud CLI not found"
  echo "  brew install hcloud  (macOS)"
  echo "  nix shell nixpkgs#hcloud  (nix)"
  exit 1
fi

if [ ! -f "$SSH_PUB_KEY" ]; then
  echo "error: SSH public key not found at $SSH_PUB_KEY"
  echo "generate one: ssh-keygen -t ed25519 -f keys/deploy -C damsac-deploy"
  exit 1
fi

# --- Check for existing server ---

EXISTING_IP=$(hcloud server describe "$SERVER_NAME" -o json 2>/dev/null | jq -r '.public_net.ipv4.ip // empty' || true)

if [ -n "$EXISTING_IP" ]; then
  echo "server '$SERVER_NAME' already exists at $EXISTING_IP"
  echo "to recreate, run teardown.sh first"
  exit 0
fi

# --- Register SSH key (idempotent) ---

if ! hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  echo "creating SSH key resource '$SSH_KEY_NAME'..."
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$SSH_PUB_KEY"
else
  echo "SSH key '$SSH_KEY_NAME' already exists in Hetzner"
fi

# --- Create server ---

echo "creating server '$SERVER_NAME' (type=$SERVER_TYPE, location=$LOCATION, image=$IMAGE)..."
hcloud server create \
  --name "$SERVER_NAME" \
  --type "$SERVER_TYPE" \
  --location "$LOCATION" \
  --image "$IMAGE" \
  --ssh-key "$SSH_KEY_NAME"

# --- Wait for server and get IP ---

echo "waiting for server to be running..."
SERVER_IP=""
for i in $(seq 1 30); do
  STATUS=$(hcloud server describe "$SERVER_NAME" -o json | jq -r '.status')
  if [ "$STATUS" = "running" ]; then
    SERVER_IP=$(hcloud server describe "$SERVER_NAME" -o json | jq -r '.public_net.ipv4.ip')
    break
  fi
  sleep 2
done

if [ -z "$SERVER_IP" ]; then
  echo "error: server did not reach running state within 60 seconds"
  exit 1
fi

echo "server running at $SERVER_IP"

# --- Wait for SSH to be reachable ---

echo "waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i keys/deploy "root@${SERVER_IP}" "true" 2>/dev/null; then
    break
  fi
  sleep 2
done

# --- Install NixOS via nixos-anywhere ---

echo "installing NixOS via nixos-anywhere..."
echo "this will partition the disk, install NixOS, and reboot the server"
echo ""

nix run github:nix-community/nixos-anywhere -- \
  --flake ".#damsac" \
  -i keys/deploy \
  --ssh-option "StrictHostKeyChecking=no" \
  --ssh-option "UserKnownHostsFile=/dev/null" \
  "root@${SERVER_IP}"

echo ""
echo "======================================"
echo "NixOS installed successfully!"
echo "Server IP: $SERVER_IP"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. SSH in and create the dashboard password:"
echo "     ssh root@$SERVER_IP 'mkdir -p /run/secrets && echo \"your-password\" > /run/secrets/damsac-dashboard-pw && chmod 600 /run/secrets/damsac-dashboard-pw'"
echo ""
echo "  2. Clone repos into /srv/damsac/:"
echo "     ssh root@$SERVER_IP 'cd /srv/damsac && git clone git@github.com:damsac/damsac-studio.git && git clone git@github.com:damsac/Murmur.git'"
echo ""
echo "  3. Deploy:"
echo "     scripts/deploy.sh $SERVER_IP"
echo ""
echo "  4. SSH in as your user and authenticate:"
echo "     ssh gudnuf@$SERVER_IP"
echo "     claude  # authenticate Claude Code"
echo "     gh auth login  # authenticate GitHub CLI"
