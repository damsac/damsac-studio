# Studio Forge: Shared Development Server

**Date:** 2026-03-21
**Status:** Draft
**Authors:** gudnuf + claude

## Summary

Evolve the damsac-studio Hetzner VPS from a single-purpose analytics deploy target into a shared development environment where both team members and Claude Code agents can SSH in, build together, and iterate on the studio and its ecosystem.

## Context

damsac-studio currently deploys as a hardened NixOS service via rsync + `nixos-rebuild`. The server runs the Go analytics API behind Caddy — nothing else. Development happens exclusively on local machines.

The team (gudnuf + isaac) collaborates async via Claude Code across multiple repos (Murmur, Slate, damsac-studio). All repos use Nix flakes. Claude Code is installed via `github:sadjow/claude-code-nix` overlay on the local Mac.

The goal: make the VPS a place where two humans + Claude Code can SSH in and build software together, with the analytics dashboard continuing to run alongside.

## Architecture

### Two NixOS Configurations, One Flake

The damsac-studio `flake.nix` defines two `nixosConfigurations`:

- **`.#damsac`** (prod) — Nix-built Go binary, hardened systemd service, Caddy reverse proxy. Same as today but with users, tools, and workspace added.
- **`.#damsac-dev`** (dev) — Same base system, but the studio service runs `air` against the local git clone for hot reload during active development.

Both share: users, dev tools, Claude Code, tmux, networking, Caddy, SSH, firewall.

### Flake Inputs (new)

```nix
claude-code.url = "github:sadjow/claude-code-nix";       # Claude Code overlay
home-manager.url = "github:nix-community/home-manager";   # Per-user environments
# disko already present
```

### File Layout

New NixOS modules go in `modules/` to leverage the existing auto-import pattern in `configuration.nix` (lines 13-21 auto-import all `.nix` files from `modules/`).

```
damsac-studio/
├── flake.nix                 # Two nixosConfigurations: damsac, damsac-dev
├── module.nix                # Prod service module (unchanged)
├── module-dev.nix            # Dev service module (air hot reload)
├── configuration.nix         # Base config: networking, caddy, boot, firewall
├── disko-config.nix          # Disk layout (unchanged)
├── modules/
│   ├── users.nix             # gudnuf + isaac users, damsac group, SSH keys
│   ├── workspace.nix         # /srv/damsac/ directory, permissions
│   ├── tmux.nix              # Shared socket, helper scripts, session conventions
│   └── home.nix              # Home Manager: claude-code, dev tools, tmux, git
├── api/                      # Go API (unchanged)
├── sdk/swift/                # Swift SDK (unchanged)
├── .claude/
│   └── commands/
│       └── ship.md           # Claude Code slash command for shipping
└── scripts/
    ├── deploy.sh             # Simplified: SSH + nixos-rebuild (for remote deploy from laptop)
    └── provision.sh          # Updated for new flake shape
```

## Users & Workspace

### User Model

Two human users, both in a `damsac` group:

| User | Purpose | Shell | Home |
|------|---------|-------|------|
| `gudnuf` | Development | zsh | `/home/gudnuf` |
| `isaac` | Development | zsh | `/home/isaac` |

Both users:
- Have SSH key-only authentication
- Are in the `wheel` group (passwordless sudo — accepted trade-off for a 2-person team on a dev/staging server)
- Are in the `damsac` group (shared workspace access)
- Get identical Home Manager environments via NixOS module integration (Claude Code, dev tools, tmux)
- Have per-user git identity configured in `modules/home.nix` (separate `programs.git` blocks per user with their own `user.name` and `user.email`)

### Git Authentication

Git clones use SSH URLs (`git@github.com:damsac/...`). Each user has an SSH keypair generated on first login, with the public key added to their GitHub account. This works for both interactive use and detached Claude Code sessions (no browser flow required, no tokens on disk).

### Shared Workspace

```
/srv/damsac/                  # Root workspace, owned by root:damsac, setgid
├── damsac-studio/            # git clone of damsac/damsac-studio
└── Murmur/                   # git clone of damsac/Murmur
```

- Group `damsac`, permissions `2775` (setgid so new files inherit group)
- Both users can read/write all files
- Workspace directory is created by a systemd-tmpfiles rule (idempotent, survives rebuilds)
- Git repos are **not** cloned automatically by NixOS — first-time setup is a manual step after provisioning (clone once, then the repos are mutable state managed by the team)

## tmux Collaboration

### Shared Socket

All tmux sessions use a shared socket at `/run/tmux-damsac/` so cross-user attachment works without sudo. The directory is created by a systemd-tmpfiles rule, owned by `root:damsac`, mode `0770`.

### Session Conventions

| Session | Owner | Purpose |
|---------|-------|---------|
| `gudnuf` | gudnuf | Personal workspace — editing, Claude Code, building |
| `isaac` | isaac | Personal workspace — editing, Claude Code, building |
| `gudnuf-claude` | gudnuf | Long-running Claude Code agents, background tasks |
| `isaac-claude` | isaac | Long-running Claude Code agents, background tasks |
| `pair` | shared | Both attached, both typing — pair programming |

### Auto-Attach on Login

Each user's `.zshrc` (via Home Manager) auto-attaches to their named tmux session on SSH login. Session persists across disconnects.

### Collaboration Commands

| Command | Action |
|---------|--------|
| `dw <user>` | Read-only attach to teammate's tmux session |
| `dp` | Create or join the shared `pair` session |

## Dev/Prod Modes

### Prod Mode (`.#damsac`)

Identical to today's hardened service:
- `buildGoModule` produces the binary
- systemd service with `DynamicUser`, `ProtectSystem=strict`, `NoNewPrivileges`
- Caddy reverse proxies `:80` → `:8080`

### Dev Mode (`.#damsac-dev`)

A separate NixOS module (`module-dev.nix`) that replaces the prod service:

- **Service user:** Runs as a dedicated `damsac-dev` system user in the `damsac` group (not `DynamicUser` — needs persistent access to the workspace)
- **ExecStart:** Runs `air` (from nixpkgs, added to the system profile) in `/srv/damsac/damsac-studio/api/`
- **Working directory:** `/srv/damsac/damsac-studio/api/`
- **Environment variables:** Same as prod (`PORT`, `DATA_DIR`, `API_KEYS`, `DASHBOARD_PASSWORD_FILE`) plus `DEV=1`
- **Hardening:** Drops `ProtectSystem=strict`, `ProtectHome=true`, and `DynamicUser`. Keeps `NoNewPrivileges`.
- **ReadWritePaths:** `/srv/damsac/damsac-studio/` (for air's tmp directory and file watching)
- **ReadOnlyPaths:** Dashboard password file (same as prod)
- **Caddy:** Same config — dashboard accessible at the same URL on `:80`
- `.air.toml` already exists at `api/.air.toml`

**Known trade-off:** In dev mode, `air` restarts the Go process on every file save. Dashboard sessions are in-memory and will be cleared on restart. SSE connections will drop. This is expected during active development.

### Mode Switching Aliases

Short aliases in every user's shell (via Home Manager). `nrs` is the same mnemonic used locally for nix-darwin rebuild — intentionally kept consistent ("nix rebuild switch" regardless of platform).

| Alias | Expands to |
|-------|------------|
| `nrs` | `sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac` |
| `nrsd` | `sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac-dev` |
| `nrt` | `sudo nixos-rebuild test --flake /srv/damsac/damsac-studio#damsac` |

## Ship Workflow

### `/ship` — Claude Code Slash Command

`/ship` is a Claude Code slash command (`.claude/commands/ship.md`) that orchestrates the full ship process with AI assistance:

1. **Review** — Claude reviews all staged/unstaged changes against project standards (CLAUDE.md, code style)
2. **Clean state check** — Ensures no uncommitted work is left behind, no temporary files, no debug code
3. **Standards enforcement** — Runs `go vet`, `go build`, verifies the API starts cleanly
4. **Commit** — Claude drafts a commit message following repo conventions, user approves
5. **Push** — Pushes to GitHub
6. **Rebuild prod** — Runs `nrs` to rebuild the production NixOS configuration

The slash command pauses for human approval at the commit step.

### Manual Fallback

If Claude Code is unavailable, the same steps can be run manually:

```bash
go vet ./...
go build -o /dev/null .
git add -p && git commit
git push
nrs
```

### CLAUDE.md Standards

The existing `CLAUDE.md` defines the standards Claude Code uses during review:
- Single flat package (no internal/, no pkg/)
- stdlib `net/http` only (no framework)
- Templates in `api/templates/`, static in `api/static/`
- HTMX for dashboard interactivity
- SQLite gotchas (single connection, WAL pragmas, idempotent inserts)
- Auth via `crypto/subtle.ConstantTimeCompare`

## Home Manager

Home Manager is used as a **NixOS module** (not standalone), integrated via `home-manager.nixosModules.home-manager` in the flake. This keeps user environments in sync with the system configuration on every rebuild.

Each user gets:

**Packages (via Home Manager):**
- `claude-code` (from the `claude-code-nix` overlay)
- `git`, `tmux`, `ripgrep`, `fd`, `jq`, `htop`
- `go`, `air`, `sqlite` (for studio development)
- `curl`, `wget`

**Programs (via Home Manager):**
- `programs.git` — per-user `user.name`, `user.email`, SSH signing config
- `programs.tmux` — shared config with collaboration keybindings
- `programs.zsh` — shell with aliases (`nrs`, `nrsd`, `nrt`, `dw`, `dp`)
- `programs.direnv` — per-directory Nix environments

The `claude-code-nix` overlay is applied at the NixOS level (`nixpkgs.overlays`), making `pkgs.claude-code` available to Home Manager.

## Provisioning

First-time setup:

1. `provision.sh [region]` — Creates Hetzner VPS, installs NixOS via nixos-anywhere with the new flake
2. SSH in, create dashboard password at `/run/secrets/damsac-dashboard-pw`
3. Clone repos into `/srv/damsac/`:
   ```bash
   cd /srv/damsac
   git clone git@github.com:damsac/damsac-studio.git
   git clone git@github.com:damsac/Murmur.git
   ```
4. Each user SSHes in and runs `claude` to authenticate Claude Code

## Network

Unchanged from today:

| Port | Service |
|------|---------|
| 22 | SSH (key-only) |
| 80 | Caddy → `:8080` |
| 443 | Caddy (when domain is configured) |
| 8080 | Studio API (localhost only) |

## Future Considerations (not in scope)

- Autonomous Claude Code agents running on cron/triggers
- Marketing and video production workflows
- Additional app services beyond the studio API
- CI/CD pipelines running on the server
- Multi-app orchestration (Slate, future apps)
- Resource monitoring / capacity planning (upgrade from cpx21 when workload demands it)

These are the direction of travel but not part of this initial build.
