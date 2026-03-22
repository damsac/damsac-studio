{ pkgs, lib, ... }:

let
  # ── Workspace-level CLAUDE.md ─────────────────────────────────────
  # Read by every Claude session started under /srv/damsac/.
  # Contains Mercury instructions and workspace conventions.
  workspaceClaudeMd = pkgs.writeText "workspace-CLAUDE.md" ''
    # damsac VPS

    Shared NixOS dev server (Hetzner). Two developers: gudnuf, isaac. Version control via jj (Jujutsu) colocated with git.

    ## Mercury

    Inter-agent message bus. Binary on PATH (`mercury`). Use it for all inter-session communication.

    ### On session start

    Determine your role and subscribe:

    ```bash
    # 1. Choose your identity based on your role:
    #    alchemist              — meta-agent (strategic, never writes code)
    #    keeper:<project>       — project keeper (e.g. keeper:studio, keeper:murmur)
    #    worker:<task>           — scoped implementation worker (e.g. worker:auth, worker:sse-fix)

    # 2. Subscribe to your channels:
    mercury subscribe --as <identity> --channel status
    mercury subscribe --as <identity> --channel <your-channel>

    # 3. Announce yourself:
    mercury send --as <identity> --to status "online, <brief description of what you're doing>"
    ```

    ### Channel conventions

    | Channel | Purpose | Who subscribes |
    |---------|---------|----------------|
    | `status` | Broadcast — everyone posts session start/end, major milestones | All agents |
    | `studio` | Strategic coordination — alchemist reads, keepers report | alchemist, all keepers |
    | `keeper:<project>` | Project-specific updates and delegation | keeper for that project, alchemist |
    | `workers` | Implementation tasks dispatched by alchemist/keepers | Workers, alchemist |

    ### During your session

    - Post status updates on significant progress: `mercury send --as <identity> --to status "completed X, starting Y"`
    - Check for messages periodically: `mercury read --as <identity>`
    - When done or ending session: `mercury send --as <identity> --to status "signing off, completed: <summary>"`

    ### Commands reference

    ```bash
    mercury send --as NAME --to CHANNEL "message"     # Send
    mercury read --as NAME                              # Read unread (all subscribed channels)
    mercury read --as NAME --channel CH                 # Read unread (specific channel)
    mercury subscribe --as NAME --channel CH            # Subscribe
    mercury unsubscribe --as NAME --channel CH          # Unsubscribe
    mercury channels                                    # List channels with messages
    mercury log --channel CH --limit N                  # Show history
    ```

    ## Workspaces

    | Path | jj workspace | Purpose |
    |------|-------------|---------|
    | `/srv/damsac/gudnuf` | `gudnuf` | gudnuf's dev workspace |
    | `/srv/damsac/isaac` | `isaac` | isaac's dev workspace |
    | `/srv/damsac/damsac-studio` | `default` | Deploy workspace — `nrs`/`nrsd` build from here |

    Each workspace has its own working copy. Edits in one do NOT affect others. All share the same repo history.

    ## jj workflow

    - **Work in your user's workspace** (`/srv/damsac/$USER`), never in `damsac-studio` directly
    - **One change per logical unit** — `jj new main -m "description"` before starting something new
    - **Describe early** — `jj describe -m "what and why"`
    - **`jj new` when done** — start fresh for the next thing
    - **Split if needed** — `jj split <files>` if multiple concerns land in one change
    - **Push to GitHub** — `jj git push`

    ## Key commands

    ```
    jj log                         # Commit graph (default command)
    jj status                      # Working copy changes
    jj new main -m "description"   # New change off main
    jj describe -m "msg"           # Describe current change
    jj edit <change-id>            # Switch to existing change
    jj diff                        # Diff of current change
    jj split                       # Split change into two
    jj git push                    # Push to GitHub
    jj undo                        # Undo last operation
    ```

    ## Collaboration rules

    - **Do NOT edit another workspace's working-copy change** — each workspace owns its `@`
    - **Do NOT commit in the deploy workspace** — it's for builds only
    - Use `jj log` to see what the other developer is working on before starting related work

    ## Shell aliases

    ```
    nrs   # Rebuild prod (always from deploy workspace)
    nrsd  # Rebuild dev mode (always from deploy workspace)
    nrt   # Test rebuild
    cdw   # cd to your workspace
    cdd   # cd to deploy workspace
    dw    # Watch teammate's tmux session
    dp    # Join shared pair session
    ```
  '';

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
        "Bash(mercury:*)"
        "Bash(jj:*)"
      ];
    };
    enabledPlugins = {
      "discord@claude-plugins-official" = true;
    };
    mcpServers = {
      mercury = {
        command = "/bin/sh";
        args = ["-c" "cd ~/.claude/plugins/mercury && bun run --silent start"];
      };
    };
  });

  # ── Mercury channel plugin ────────────────────────────────────────
  # Copy plugin source into the Nix store at build time so activation
  # doesn't depend on any specific workspace having the files.
  mercuryPluginSrc = builtins.path {
    path = ../plugins/mercury;
    name = "mercury-plugin";
  };

  # ── Metacraft skills ─────────────────────────────────────────────
  metacraftSrc = builtins.path {
    path = ../skills/metacraft;
    name = "metacraft-skills";
  };

  # ── User-level settings (per-user ~/.claude/settings.local.json) ──
  # Contains MCP server configs that need to be available globally,
  # regardless of which project directory Claude is launched from.
  userSettings = pkgs.writeText "user-settings.local.json" (builtins.toJSON {
    mcpServers = {
      mercury = {
        command = "/bin/sh";
        args = ["-c" "cd ~/.claude/plugins/mercury && bun run --silent start"];
      };
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
    "d /home/gudnuf/.claude/plugins/mercury 0755 gudnuf users - -"
    "d /home/gudnuf/.claude/plugins/mercury/.claude-plugin 0755 gudnuf users - -"
    "d /home/isaac/.claude/plugins/mercury 0755 isaac users - -"
    "d /home/isaac/.claude/plugins/mercury/.claude-plugin 0755 isaac users - -"
  ];

  # Write project and workspace files on every activation.
  # These are copies (not symlinks) so they're mutable between rebuilds.
  # nrs/nrsd resets them to the state declared above.
  system.activationScripts.claude-config = lib.stringAfter [ "etc" ] ''
    install -m 0664 -o root -g damsac ${workspaceClaudeMd} ${workspaceDir}/.claude/CLAUDE.md
    install -m 0664 -o root -g damsac ${claudeMd} ${projectDir}/CLAUDE.md
    install -m 0664 -o root -g damsac ${shipCommand} ${projectDir}/.claude/commands/ship.md
    install -m 0664 -o root -g damsac ${workspaceSettings} ${workspaceDir}/.claude/settings.local.json

    # Mercury MCP server registration + channel plugin files
    for user in gudnuf isaac; do
      mkdir -p /home/''${user}/.claude/plugins/mercury/.claude-plugin
      install -m 0644 -o ''${user} -g users ${mercuryPluginSrc}/server.ts /home/''${user}/.claude/plugins/mercury/server.ts
      install -m 0644 -o ''${user} -g users ${mercuryPluginSrc}/package.json /home/''${user}/.claude/plugins/mercury/package.json
      install -m 0644 -o ''${user} -g users ${mercuryPluginSrc}/tsconfig.json /home/''${user}/.claude/plugins/mercury/tsconfig.json
      install -m 0644 -o ''${user} -g users ${mercuryPluginSrc}/.mcp.json /home/''${user}/.claude/plugins/mercury/.mcp.json
      install -m 0644 -o ''${user} -g users ${mercuryPluginSrc}/.claude-plugin/plugin.json /home/''${user}/.claude/plugins/mercury/.claude-plugin/plugin.json

      # Metacraft skills
      for skill in gather genesis lanes-plan lanes-status meta-agent session-lifecycle tmux-lanes; do
        mkdir -p /home/''${user}/.claude/skills/metacraft/$skill
        install -m 0644 -o ''${user} -g users ${metacraftSrc}/$skill/SKILL.md /home/''${user}/.claude/skills/metacraft/$skill/SKILL.md
      done
      install -m 0644 -o ''${user} -g users ${metacraftSrc}/PHILOSOPHY.md /home/''${user}/.claude/skills/metacraft/PHILOSOPHY.md
    done
  '';

}
