# damsac-studio

Self-hosted analytics platform for indie app studios. Go API + SQLite + Swift SDK + NixOS deployment.

## Commands

### API (Go)
nix develop                    # Dev shell (Go, SQLite, air, gopls, hcloud, jq)
cd api && go run .             # Run locally on :8080
cd api && go build -o api      # Build binary

### Swift SDK
cd sdk/swift && swift build    # Build SDK
cd sdk/swift && swift test     # Run tests

### Deploy
scripts/provision.sh [region]  # Create Hetzner VPS + install NixOS (ash|fal|nbg|fsn|hel|sin|sgp)
scripts/deploy.sh $VPS_IP      # Deploy via rsync + nixos-rebuild
damsac-status                  # Health check
damsac-logs                    # View remote logs
damsac-ssh                     # SSH into VPS

### Server Development (SSH into VPS)
nrs                            # Rebuild prod (nixos-rebuild switch)
nrsd                           # Rebuild dev mode (air hot reload)
nrt                            # Test rebuild (nixos-rebuild test)
dw <user>                      # Watch teammate's tmux session (read-only)
dp                             # Join/create shared pair session
/ship                          # Claude-assisted: review, commit, push, rebuild

## Architecture

- `api/` — Go HTTP API (single flat package, stdlib net/http, no framework)
- `sdk/swift/` — iOS analytics SDK (Swift Package, iOS 17+/macOS 14+)
- `module.nix` — NixOS service module (systemd, hardened)
- `configuration.nix` — VPS config (Caddy reverse proxy, SSH, firewall)
- `flake.nix` — Nix flake (dev shell + NixOS config)
- `scripts/` — Provision, deploy, SSH, logs, status, teardown
- `docs/` — Design specs (MVP, LLM tracking schema)
- `infra/` — Hetzner secrets (git-ignored)
- `keys/` — SSH deploy keys (private key git-ignored)
- `module-dev.nix` — Dev mode service (air hot reload, relaxed hardening)
- `modules/` — NixOS modules (users, workspace, tmux, home-manager) — auto-imported by configuration.nix

## API Endpoints

- `POST /v1/events` — Event ingest (auth: `X-API-Key` header, returns 202)
- `GET /v1/health` — Liveness check (unauthenticated)
- `GET /dashboard` — Analytics dashboard (session cookie auth)
- `GET /dashboard/events/stream` — SSE real-time events
- `GET /projects` — GitHub project board (requires GITHUB_TOKEN)

## Environment Variables

Required: `API_KEYS` (comma-separated `key:app_id`), `DASHBOARD_PASSWORD_FILE` (path to password file)
Optional: `PORT` (default 8080), `DATA_DIR` (default `.`), `GITHUB_TOKEN`, `DASHBOARD_SECURE_COOKIE`

## Gotchas

- SQLite single connection (`MaxOpenConns=1`) — required for WAL pragmas to apply globally
- Timestamps accept both RFC3339 and RFC3339Nano (fractional seconds from iOS)
- Event insert is idempotent (`INSERT OR IGNORE` on client-provided UUID)
- Hetzner resets UEFI NVRAM on reboot — uses GRUB + BIOS boot partition, not systemd-boot
- Dashboard sessions are in-memory (64-byte random tokens, not JWT) — restart clears sessions
- SSE broker drops messages to slow subscribers (channel buffer 16) rather than blocking ingest
- Auth uses `crypto/subtle.ConstantTimeCompare` — don't replace with `==`

## Code Style

- Go API is a single flat package (no internal/, no pkg/) — all files in `api/`
- No web framework — stdlib `net/http` with `http.NewServeMux`
- Templates in `api/templates/`, static assets in `api/static/`
- HTMX for dashboard interactivity
