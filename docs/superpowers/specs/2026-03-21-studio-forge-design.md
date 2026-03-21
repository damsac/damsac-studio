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

```
damsac-studio/
├── flake.nix                 # Two nixosConfigurations: damsac, damsac-dev
├── module.nix                # Prod service module (unchanged)
├── module-dev.nix            # Dev service module (air hot reload)
├── configuration.nix         # Base config: networking, caddy, boot, firewall
├── users.nix                 # gudnuf + isaac users, damsac group, SSH keys
├── workspace.nix             # /srv/damsac/ setup, git clones, permissions
├── tmux.nix                  # Shared socket, helper scripts, session conventions
├── home.nix                  # Home Manager: claude-code, dev tools, tmux, git
├── disko-config.nix          # Disk layout (unchanged)
├── api/                      # Go API (unchanged)
├── sdk/swift/                # Swift SDK (unchanged)
└── scripts/
    ├── deploy.sh             # Updated for new flake shape
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
- Are in the `wheel` group (passwordless sudo)
- Are in the `damsac` group (shared workspace access)
- Get identical Home Manager environments (Claude Code, dev tools, tmux, git)
- Configure their own git identity (`user.name`, `user.email`) in their Home Manager config

### Shared Workspace

```
/srv/damsac/                  # Root workspace, owned by root:damsac, setgid
├── damsac-studio/            # git clone of damsac/damsac-studio
└── Murmur/                   # git clone of damsac/Murmur
```

- Group `damsac`, permissions `2775` (setgid so new files inherit group)
- Both users can read/write all files
- Git clones use HTTPS (no deploy keys needed — both users push with their own GitHub credentials)

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

- systemd service runs `air` in `/srv/damsac/damsac-studio/api/`
- Watches for `.go` file changes, auto-rebuilds and restarts
- Runs as a regular user (needs read/write to the workspace)
- Same Caddy config — dashboard accessible at the same URL
- `.air.toml` config already exists in `api/`

### Mode Switching Aliases

Short aliases in every user's shell (via Home Manager):

| Alias | Expands to |
|-------|------------|
| `nrs` | `sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac` |
| `nrsd` | `sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac-dev` |
| `nrt` | `sudo nixos-rebuild test --flake /srv/damsac/damsac-studio#damsac` |

## Ship Workflow

`damsac-ship` is **not** a shell script — it's a Claude Code slash command (`.claude/commands/ship.md`) that orchestrates the full ship process with AI assistance:

1. **Review** — Claude reviews all staged/unstaged changes against project standards (CLAUDE.md, code style, test coverage)
2. **Clean state check** — Ensures no uncommitted work is left behind, no temporary files, no debug code
3. **Standards enforcement** — Runs `go vet`, `go build`, verifies the API starts cleanly
4. **Commit** — Claude drafts a commit message following repo conventions, user approves
5. **Push** — Pushes to GitHub
6. **Rebuild prod** — Runs `nrs` to rebuild the production NixOS configuration from the newly pushed code

The slash command is designed so Claude Code can run the full pipeline, pausing for human approval at the commit step.

### CLAUDE.md Standards

The existing `CLAUDE.md` defines the standards Claude Code uses during review:
- Single flat package (no internal/, no pkg/)
- stdlib `net/http` only (no framework)
- Templates in `api/templates/`, static in `api/static/`
- HTMX for dashboard interactivity
- SQLite gotchas (single connection, WAL pragmas, idempotent inserts)
- Auth via `crypto/subtle.ConstantTimeCompare`

These standards are enforced during the review step of `damsac-ship`.

## Provisioning

First-time setup remains the same:

1. `provision.sh [region]` — Creates Hetzner VPS, installs NixOS via nixos-anywhere
2. SSH in as root, create dashboard password at `/run/secrets/damsac-dashboard-pw`
3. First `nixos-rebuild switch` pulls in users, tools, workspace, and clones repos
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

These are the direction of travel but not part of this initial build.
