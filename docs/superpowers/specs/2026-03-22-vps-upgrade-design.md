# VPS Upgrade: CPX21 → CPX41

## Overview

Resize the Hetzner Cloud VPS from CPX21 to CPX41 via in-place upgrade to support 12+ concurrent Claude Code sessions, multiple services, and future growth. Includes comprehensive backup of all stateful data before resize.

## Current State

**CPX21** — €7.99/mo (Falkenstein, EU)
- 3 shared vCPUs, 4GB RAM, 80GB disk
- RAM: 2.6GB used / 1.2GB available (70%) + 2GB swap (just added)
- 3 Claude Code sessions consuming ~1.9GB — one more risks swap pressure
- Disk: 18GB used / 53GB available (25%)

## Target State

**CPX41** — €27.49/mo (Falkenstein, EU)
- 8 shared vCPUs, 16GB RAM, 240GB disk
- Supports 12-16 idle Claude Code sessions (~600MB each = ~7-10GB)
- Leaves ~6-9GB for OS, services, builds, and bursts
- 240GB disk provides room for /nix/store growth, multiple workspaces, build artifacts
- **Can resize up to CPX51 (16 vCPU, 32GB, €60/mo) later if needed**

## What Needs Backup

### Critical (data loss = bad)

| Item | Location | Size | Notes |
|------|----------|------|-------|
| Analytics DB | `/var/lib/damsac-studio/studio.db` (+shm, +wal) | ~500KB | All event data from Murmur |
| Mercury DB | `/home/gudnuf/.local/share/mercury/mercury.db` (+shm, +wal) | ~44KB | Full message history |
| SSH host keys | `/etc/ssh/ssh_host_ed25519_key`, `ssh_host_rsa_key` (.pub too) | tiny | Changing these breaks known_hosts for everyone |
| Dashboard password | `/run/secrets/damsac-dashboard-pw` | tiny | Value: in systemd env, recreated from NixOS config |
| Caddy TLS certs | `/var/lib/caddy/.local/share/caddy/` | ~12KB | ACME account key + damsac.studio cert/key |
| API key | In systemd env: `sk_murmur:murmur-ios` | — | Hardcoded in module.nix, also in Murmur iOS app |

### Important (reproducible but annoying to lose)

| Item | Location | Size | Notes |
|------|----------|------|-------|
| Claude Code config | `/home/gudnuf/.claude/` | ~225MB | Sessions, plugins, skills, settings, history |
| Home directory | `/home/gudnuf/` | ~1.2GB | Go modules, claude config, local state |
| Shared workspace | `/srv/damsac/` | ~1GB total | damsac-studio, Murmur, jj workspaces |
| Holesail key | In NixOS module | — | P2P tunnel identity (changing it breaks the connection hash) |
| Discord bot token | In Claude plugin config | — | Set via `/discord:configure`, stored in plugin data dir |
| Mercury-Discord feed config | `modules/mercury-feed.nix` + `tools/mercury-discord-feed/` | — | Channel IDs, webhook config |

### Nice to have (fully reproducible)

| Item | Notes |
|------|-------|
| `/nix/store/` | Rebuilt from flake.nix on deploy |
| NixOS config | Already in git at `/srv/damsac/damsac-studio/` |
| Isaac's home dir | ~4KB, essentially empty |

## Backup Plan

Run from local Mac. All backups land in `~/damsac-backups/YYYY-MM-DD/`.

```bash
# Create backup directory
BACKUP_DIR=~/damsac-backups/$(date +%Y-%m-%d)
mkdir -p "$BACKUP_DIR"

# 1. Critical databases (stop writes first for clean copy)
# Note: studio.db is SQLite WAL mode — use sqlite3 .backup for consistency
ssh damsac "sudo sqlite3 /var/lib/damsac-studio/studio.db '.backup /tmp/studio-backup.db'"
scp damsac:/tmp/studio-backup.db "$BACKUP_DIR/studio.db"

ssh damsac "sqlite3 /home/gudnuf/.local/share/mercury/mercury.db '.backup /tmp/mercury-backup.db'"
scp damsac:/tmp/mercury-backup.db "$BACKUP_DIR/mercury.db"

# 2. SSH host keys (preserves known_hosts trust)
ssh damsac "sudo tar czf /tmp/ssh-host-keys.tar.gz /etc/ssh/ssh_host_*"
scp damsac:/tmp/ssh-host-keys.tar.gz "$BACKUP_DIR/"

# 3. Caddy state (TLS certs + ACME account)
ssh damsac "sudo tar czf /tmp/caddy-state.tar.gz /var/lib/caddy/"
scp damsac:/tmp/caddy-state.tar.gz "$BACKUP_DIR/"

# 4. Claude Code config (sessions, plugins, skills, settings)
rsync -az damsac:/home/gudnuf/.claude/ "$BACKUP_DIR/claude-config/"

# 5. Full home directory (includes go modules, mercury, claude)
rsync -az damsac:/home/gudnuf/ "$BACKUP_DIR/home-gudnuf/"

# 6. Shared workspace (repos, workspaces)
rsync -az damsac:/srv/damsac/ "$BACKUP_DIR/srv-damsac/"

# 7. Secrets snapshot (for reference — these are in NixOS config)
ssh damsac "sudo cat /run/secrets/damsac-dashboard-pw" > "$BACKUP_DIR/dashboard-password.txt"
ssh damsac "sudo systemctl cat damsac-studio.service | grep API_KEYS" > "$BACKUP_DIR/api-keys-ref.txt"

# 8. NixOS config as deployed (may differ from git)
rsync -az damsac:/etc/nixos/ "$BACKUP_DIR/etc-nixos/"

# 9. Verify
echo "Backup complete. Contents:"
du -sh "$BACKUP_DIR"/*
```

## Resize Procedure

### Pre-resize
1. Run full backup (above)
2. Verify backups are readable locally
3. Stop all Claude Code sessions on VPS (tmux kill-server or graceful shutdown)
4. Optional: `ssh damsac "sudo systemctl stop damsac-studio"` to ensure clean DB state

### Resize
1. Go to Hetzner Cloud Console → Servers → damsac → Rescale
2. Or via API: `hcloud server change-type --server damsac --server-type cpx41`
3. Server will shut down, resize, and restart (~1-3 minutes)
4. **Disk resize is permanent** — cannot downgrade from 240GB back to 80GB later

### Post-resize
1. SSH in, verify: `free -h` shows 16GB RAM, `nproc` shows 8, `df -h` shows 240GB
2. Resize filesystem if needed (Hetzner usually auto-extends, but verify)
3. `sudo nixos-rebuild switch` to re-apply config (picks up swap, services)
4. Verify services: `systemctl status damsac-studio caddy holesail-ssh mercury-discord-feed`
5. Verify Mercury: `mercury channels` and `mercury log --limit 5`
6. Restart tmux sessions, relaunch Claude Code agents
7. Update swap size in `configuration.nix` — bump from 2GB to 4GB (appropriate for 16GB RAM box)
8. Health check: `curl https://damsac.studio/v1/health`

### Post-resize config changes
- Bump swap to 4GB in `configuration.nix` (currently 2GB, sized for 4GB box)
- Deploy updated config: `scripts/deploy.sh`

## Growth Path

If CPX41 becomes tight:
- **CPX51**: 16 vCPU, 32GB RAM, 360GB disk — €60.49/mo (resize in-place again)
- **CCX33**: 8 dedicated vCPU, 32GB RAM, 240GB disk — €53.49/mo (requires migration, not in-place)

Dedicated vCPUs (CCX) require provisioning a new server — can't resize from shared (CPX) to dedicated in-place. Cross that bridge if shared vCPU contention becomes a problem.

## Cost

- Current: €7.99/mo
- After upgrade: €27.49/mo
- Delta: +€19.50/mo (~$21 USD)
- Annual: ~€330/yr (~$360 USD)
