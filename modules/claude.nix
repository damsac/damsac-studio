{ pkgs, lib, ... }:

let
  # ── Project CLAUDE.md ──────────────────────────────────────────────
  claudeMd = pkgs.writeText "CLAUDE.md" ''
    # damsac-studio

    Self-hosted analytics platform for indie app studios. Go API + SQLite + Swift SDK + NixOS deployment.

    ## Commands

    ### API (Go)
    nix develop                    # Dev shell (Go, SQLite, air, gopls, hcloud, jq)
    cd api && go run .             # Run locally on :8080
    cd api && go build -o api      # Build binary
    scripts/dev                     # Run dev server (sets API_KEYS=devkey:dev-app)
    cd api && go test -v ./...      # Run tests

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
    - `modules/` — NixOS modules (users, workspace, tmux, home-manager, claude) — auto-imported by configuration.nix
    - `modules/claude.nix` — Declarative Claude Code config (CLAUDE.md, MCP, commands, settings)

    ## API Endpoints

    - `POST /v1/events` — Event ingest (auth: `X-API-Key` header, returns 202)
    - `GET /v1/health` — Liveness check (unauthenticated)
    - `GET /dashboard` — Analytics dashboard (session cookie auth)
    - `GET /dashboard/events/stream` — SSE real-time events
    - `GET /projects` — GitHub project board (requires GITHUB_TOKEN)
    - `POST|GET|DELETE /mcp` — MCP Streamable HTTP endpoint (auth: `X-API-Key` header, read-only SQL query tool)

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
    - `modernc.org/sqlite` strips query params from plain-path DSNs — must use `file:` URI format (e.g. `file:path?mode=ro`) for params to take effect
    - Read-only DB (`OpenReadOnlyDB`) uses DSN-level `_pragma` so pool can have >1 conn (unlike write conn's `MaxOpenConns=1`)
    - Prod is behind Caddy on port 80 — port 8080 is not open externally
    - Claude Code config is declarative — managed by `modules/claude.nix`, reset on `nrs`/`nrsd`

    ## Code Style

    - Go API is a single flat package (no internal/, no pkg/) — all files in `api/`
    - No web framework — stdlib `net/http` with `http.NewServeMux`
    - Templates in `api/templates/`, static assets in `api/static/`
    - HTMX for dashboard interactivity
  '';

  # ── Slash commands ─────────────────────────────────────────────────
  shipCommand = pkgs.writeText "ship.md" ''
    Review all staged and unstaged changes in the current repository against the project standards defined in CLAUDE.md.

    Steps:
    1. Run `git status` and `git diff` to see all changes
    2. Review every change for:
       - Code style: single flat package, stdlib net/http only, no framework
       - Templates in api/templates/, static assets in api/static/
       - HTMX for dashboard interactivity
       - SQLite safety: single connection, WAL pragmas, idempotent inserts
       - Auth uses crypto/subtle.ConstantTimeCompare (never ==)
       - No debug code, no temporary files, no hardcoded secrets
    3. Run `cd api && go vet ./...` to check for issues
    4. Run `cd api && go build -o /dev/null .` to verify compilation
    5. If issues found, report them and stop. Do not commit broken code.
    6. If everything passes, draft a commit message following the repo's conventional commit style (look at recent `git log --oneline -10` for examples)
    7. Stage relevant files and commit (pause for user approval on the commit message)
    8. Run `git push`
    9. Ask the user if they want to rebuild prod now (`nrs`) or stay in dev mode
  '';

  # ── Workspace settings ─────────────────────────────────────────────
  workspaceSettings = pkgs.writeText "settings.local.json" (builtins.toJSON {
    permissions = {
      allow = [
        "Bash(curl:*)"
        "Bash(systemctl status:*)"
        "Bash(gh repo:*)"
      ];
    };
  });

  # ── Paths ──────────────────────────────────────────────────────────
  projectDir = "/srv/damsac/damsac-studio";
  workspaceDir = "/srv/damsac";

in
{
  # Create directories
  systemd.tmpfiles.rules = [
    "d ${projectDir}/.claude 2775 root damsac - -"
    "d ${projectDir}/.claude/commands 2775 root damsac - -"
    "d ${workspaceDir}/.claude 2775 root damsac - -"
  ];

  # Write project and workspace files on every activation.
  # These are copies (not symlinks) so they're mutable between rebuilds.
  # nrs/nrsd resets them to the state declared above.
  system.activationScripts.claude-config = lib.stringAfter [ "etc" ] ''
    install -m 0664 -o root -g damsac ${claudeMd} ${projectDir}/CLAUDE.md
    install -m 0664 -o root -g damsac ${shipCommand} ${projectDir}/.claude/commands/ship.md
    install -m 0664 -o root -g damsac ${workspaceSettings} ${workspaceDir}/.claude/settings.local.json
  '';

}
