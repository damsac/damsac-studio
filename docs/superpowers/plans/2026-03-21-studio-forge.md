# Studio Forge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the damsac-studio VPS from a single-purpose deploy target into a shared development environment with per-user Home Manager configs, Claude Code, tmux collaboration, dev/prod mode switching, and a Claude-assisted ship workflow.

**Architecture:** Two NixOS configurations (`#damsac` prod, `#damsac-dev` dev) in a single flake. New modules in `modules/` for users, workspace, tmux, and Home Manager. Dev mode replaces the hardened prod service with `air` hot reload against the local git clone.

**Tech Stack:** NixOS, Nix flakes, Home Manager, Claude Code (via `claude-code-nix`), tmux, Caddy, Go, air

**Spec:** `docs/superpowers/specs/2026-03-21-studio-forge-design.md`

---

### Task 1: Add flake inputs (claude-code-nix, home-manager)

**Files:**
- Modify: `flake.nix:1-11` (inputs block)

- [ ] **Step 1: Add claude-code and home-manager inputs to flake.nix**

Add two new inputs after the existing `disko` input:

```nix
claude-code = {
  url = "github:sadjow/claude-code-nix";
};

home-manager = {
  url = "github:nix-community/home-manager";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

- [ ] **Step 2: Update outputs function signature**

Change the outputs line (`flake.nix:13`) to include the new inputs:

```nix
outputs = { self, nixpkgs, flake-utils, disko, claude-code, home-manager }:
```

- [ ] **Step 3: Add claude-code overlay to nixpkgs.overlays**

In the existing `nixosConfigurations.damsac` module list (`flake.nix:70-73`), add the claude-code overlay alongside the existing one:

```nix
{
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.overlays = [ overlay claude-code.overlays.default ];
}
```

- [ ] **Step 4: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: No evaluation errors (build errors are OK since we're on darwin, not x86_64-linux)

- [ ] **Step 5: Commit (including flake.lock)**

```bash
git add flake.nix flake.lock
git commit -m "feat: add claude-code-nix and home-manager flake inputs"
```

---

### Task 2: Create modules/users.nix — user accounts and damsac group

**Files:**
- Create: `modules/users.nix`
- Modify: `configuration.nix:70-72` (remove root-only SSH keys, now handled by users.nix)

- [ ] **Step 1: Create modules/ directory**

```bash
mkdir -p modules
```

- [ ] **Step 2: Write modules/users.nix**

```nix
{ pkgs, ... }:

{
  # Shared group for workspace access
  users.groups.damsac = {};

  # Disable mutable users — all user config is declarative
  users.mutableUsers = false;

  users.users.gudnuf = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "damsac" ];
    openssh.authorizedKeys.keys = [
      # TODO: Replace with gudnuf's actual SSH public key
      "ssh-ed25519 AAAA... gudnuf"
    ];
  };

  users.users.isaac = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "damsac" ];
    openssh.authorizedKeys.keys = [
      # TODO: Replace with isaac's actual SSH public key
      "ssh-ed25519 AAAA... isaac"
    ];
  };

  # Passwordless sudo for wheel group
  security.sudo.wheelNeedsPassword = false;

  # Root keeps the existing deploy key for provisioning/emergency
  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ../keys/deploy.pub)
  ];

  # Enable zsh system-wide (required for user shells)
  programs.zsh.enable = true;
}
```

**Important:** Both user SSH keys are marked TODO. Before deploying, replace them with the actual public keys from each person's machine. Do NOT deploy with placeholder keys — `users.mutableUsers = false` means SSH keys are the only way in.

- [ ] **Step 3: Remove old root SSH key from configuration.nix**

Remove lines 70-72 from `configuration.nix`:
```nix
  users.users.root.openssh.authorizedKeys.keys = [
    (builtins.readFile ./keys/deploy.pub)
  ];
```

These are now handled in `modules/users.nix`. The `keys/deploy.pub` file reference would break on the server where the file path differs.

- [ ] **Step 4: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: No evaluation errors

- [ ] **Step 5: Commit**

```bash
git add modules/users.nix configuration.nix
git commit -m "feat: add user accounts (gudnuf, isaac) and damsac group"
```

---

### Task 3: Create modules/workspace.nix — shared workspace directory

**Files:**
- Create: `modules/workspace.nix`

- [ ] **Step 1: Write modules/workspace.nix**

```nix
{ ... }:

{
  # Create /srv/damsac/ with setgid so new files inherit the damsac group.
  # Git repos are cloned manually after provisioning (mutable state).
  systemd.tmpfiles.rules = [
    "d /srv/damsac 2775 root damsac - -"
  ];
}
```

- [ ] **Step 2: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add modules/workspace.nix
git commit -m "feat: add shared workspace directory at /srv/damsac/"
```

---

### Task 4: Create modules/tmux.nix — shared socket and collaboration scripts

**Files:**
- Create: `modules/tmux.nix`

- [ ] **Step 1: Write modules/tmux.nix**

```nix
{ pkgs, ... }:

let
  # dw <user> — read-only attach to a teammate's tmux session
  damsac-watch = pkgs.writeShellScriptBin "dw" ''
    if [ -z "$1" ]; then
      echo "usage: dw <username>"
      echo ""
      echo "Available sessions:"
      ${pkgs.tmux}/bin/tmux -S /run/tmux-damsac/shared list-sessions 2>/dev/null || echo "  (none)"
      exit 1
    fi
    exec ${pkgs.tmux}/bin/tmux -S /run/tmux-damsac/shared attach -t "$1" -r
  '';

  # dp — create or join the shared pair session
  damsac-pair = pkgs.writeShellScriptBin "dp" ''
    SOCKET="/run/tmux-damsac/shared"
    if ! ${pkgs.tmux}/bin/tmux -S "$SOCKET" has -t pair 2>/dev/null; then
      ${pkgs.tmux}/bin/tmux -S "$SOCKET" new-session -d -s pair -c /srv/damsac
    fi
    exec ${pkgs.tmux}/bin/tmux -S "$SOCKET" attach -t pair
  '';
in
{
  # Shared tmux socket directory — allows cross-user session attachment
  systemd.tmpfiles.rules = [
    "d /run/tmux-damsac 0770 root damsac - -"
  ];

  # Make helper scripts available system-wide
  environment.systemPackages = [
    damsac-watch
    damsac-pair
  ];
}
```

- [ ] **Step 2: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add modules/tmux.nix
git commit -m "feat: add tmux collaboration — shared socket, dw, dp commands"
```

---

### Task 5: Create modules/home.nix — Home Manager per-user environments

**Files:**
- Create: `modules/home.nix`
- Modify: `flake.nix` (wire home-manager NixOS module into both configurations)

- [ ] **Step 1: Write modules/home.nix**

```nix
{ pkgs, ... }:

let
  # Shared Home Manager config applied to all damsac users
  sharedHome = { username, realName, email }: {
    home.stateVersion = "24.11";
    home.username = username;
    home.homeDirectory = "/home/${username}";

    home.packages = with pkgs; [
      # AI tools
      claude-code

      # Dev tools
      go
      air
      sqlite
      gopls

      # GitHub
      gh

      # Search and navigation
      ripgrep
      fd
      jq
      htop

      # Networking
      curl
      wget

      # Nix
      nil
    ];

    programs.git = {
      enable = true;
      userName = realName;
      userEmail = email;
    };

    programs.tmux = {
      enable = true;
      clock24 = true;
      keyMode = "vi";
      terminal = "screen-256color";
      historyLimit = 50000;
      baseIndex = 1;
      escapeTime = 0;
      extraConfig = ''
        set -g mouse on
        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"
        bind h select-pane -L
        bind j select-pane -D
        bind k select-pane -U
        bind l select-pane -R
      '';
    };

    programs.zsh = {
      enable = true;
      shellAliases = {
        nrs = "sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac";
        nrsd = "sudo nixos-rebuild switch --flake /srv/damsac/damsac-studio#damsac-dev";
        nrt = "sudo nixos-rebuild test --flake /srv/damsac/damsac-studio#damsac";
      };
      initContent = ''
        # Auto-attach to personal tmux session on SSH login
        if [[ -n "$SSH_CONNECTION" ]] && [[ -z "$TMUX" ]]; then
          SOCKET="/run/tmux-damsac/shared"
          SESSION="$USER"
          if ! tmux -S "$SOCKET" has -t "$SESSION" 2>/dev/null; then
            tmux -S "$SOCKET" new-session -d -s "$SESSION" -c /srv/damsac
          fi
          exec tmux -S "$SOCKET" attach -t "$SESSION"
        fi

        # Default working directory
        if [[ "$PWD" == "$HOME" ]]; then
          cd /srv/damsac
        fi
      '';
    };

    programs.direnv = {
      enable = true;
      enableZshIntegration = true;
      nix-direnv.enable = true;
    };
  };
in
{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.users.gudnuf = sharedHome {
    username = "gudnuf";
    realName = "gudnuf";
    email = "gudnuf@users.noreply.github.com";
  };

  home-manager.users.isaac = sharedHome {
    username = "isaac";
    realName = "IsaacMenge";
    email = "IsaacMenge@users.noreply.github.com";
  };
}
```

- [ ] **Step 2: Wire home-manager NixOS module into flake.nix**

In the `nixosConfigurations.damsac` modules list, add:

```nix
home-manager.nixosModules.home-manager
```

The full modules list becomes:

```nix
nixosConfigurations.damsac = nixpkgs.lib.nixosSystem {
  modules = [
    disko.nixosModules.disko
    home-manager.nixosModules.home-manager
    self.nixosModules.default
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      nixpkgs.overlays = [ overlay claude-code.overlays.default ];
    }
    ./disko-config.nix
    ./configuration.nix
  ];
};
```

- [ ] **Step 3: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add modules/home.nix flake.nix
git commit -m "feat: add Home Manager — claude-code, dev tools, tmux, zsh per user"
```

---

### Task 6: Create module-dev.nix — dev mode service with air hot reload

**Files:**
- Create: `module-dev.nix`

- [ ] **Step 1: Write module-dev.nix**

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.damsac-studio-dev;
in
{
  options.services.damsac-studio-dev = {
    enable = lib.mkEnableOption "damsac-studio dev mode (air hot reload)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    workspaceDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/damsac/damsac-studio";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/damsac-studio";
    };

    apiKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    dashboardPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };

    secureCookie = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    # Dev service user — needs workspace access
    users.users.damsac-dev = {
      isSystemUser = true;
      group = "damsac";
      home = "/var/lib/damsac-dev";
      createHome = true;
    };

    systemd.services.damsac-studio = {
      description = "damsac-studio dev server (air hot reload)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        PORT = toString cfg.port;
        DATA_DIR = cfg.dataDir;
        API_KEYS = lib.concatStringsSep "," cfg.apiKeys;
        DASHBOARD_SECURE_COOKIE = if cfg.secureCookie then "true" else "false";
        DEV = "1";
        HOME = "/var/lib/damsac-dev";
      } // lib.optionalAttrs (cfg.dashboardPasswordFile != null) {
        DASHBOARD_PASSWORD_FILE = toString cfg.dashboardPasswordFile;
      };

      path = [ pkgs.go pkgs.git ];

      serviceConfig = {
        # Fix ownership when switching from prod (DynamicUser) to dev mode
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 -o damsac-dev -g damsac ${cfg.dataDir}";
        ExecStart = "${pkgs.air}/bin/air";
        WorkingDirectory = "${cfg.workspaceDir}/api";
        Restart = "on-failure";
        RestartSec = 2;

        User = "damsac-dev";
        Group = "damsac";
        NoNewPrivileges = true;
        StateDirectory = "damsac-studio";
        ReadWritePaths = [
          cfg.workspaceDir
          cfg.dataDir
        ];
      } // lib.optionalAttrs (cfg.dashboardPasswordFile != null) {
        ReadOnlyPaths = [ cfg.dashboardPasswordFile ];
      };
    };
  };
}
```

- [ ] **Step 2: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add module-dev.nix
git commit -m "feat: add dev mode service module — air hot reload for studio"
```

---

### Task 7: Add damsac-dev config and move service settings to flake

**Files:**
- Modify: `flake.nix` (add dev module, second nixosConfiguration, move service settings)
- Modify: `configuration.nix:23-31` (remove service config — now per-configuration in flake)

These must be done together: the dev config cannot reference `services.damsac-studio` options unless the prod module is imported, and `configuration.nix` currently sets those options which breaks the dev config if the module isn't loaded.

- [ ] **Step 1: Remove service config from configuration.nix**

Remove lines 23-31 from `configuration.nix`:
```nix
  # --- damsac-studio analytics service ---
  services.damsac-studio = {
    enable = true;
    port = 8080;
    dataDir = "/var/lib/damsac-studio";
    apiKeys = [ "sk_murmur:murmur-ios" ];
    dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
    secureCookie = domain != ":80";
  };
```

Also remove the `domain` let-binding (lines 3-8) since it's no longer used:
```nix
let
  domain = ":80";
in
```

Change the opening `{` to not use `in`:
```nix
{ config, pkgs, lib, ... }:
{
  # Auto-import all .nix files from modules/ ...
```

- [ ] **Step 2: Add `lib` binding and register dev module in flake.nix**

Add `lib = nixpkgs.lib;` at the top of the `let` block (after line 14):

```nix
let
  lib = nixpkgs.lib;
  mkPackage = pkgs: pkgs.buildGoModule { ...
```

Add after the existing `nixosModules.default` line:

```nix
nixosModules.dev = import ./module-dev.nix;
```

- [ ] **Step 3: Move service settings into prod config inline module in flake.nix**

Update the existing `nixosConfigurations.damsac` to include service settings:

```nix
nixosConfigurations.damsac = nixpkgs.lib.nixosSystem {
  modules = [
    disko.nixosModules.disko
    home-manager.nixosModules.home-manager
    self.nixosModules.default
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      nixpkgs.overlays = [ overlay claude-code.overlays.default ];
      services.damsac-studio = {
        enable = true;
        port = 8080;
        dataDir = "/var/lib/damsac-studio";
        apiKeys = [ "sk_murmur:murmur-ios" ];
        dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
        secureCookie = false; # using :80, no HTTPS yet
      };
    }
    ./disko-config.nix
    ./configuration.nix
  ];
};
```

- [ ] **Step 4: Add damsac-dev nixosConfiguration**

The dev config imports BOTH modules (prod module for option definitions, dev module for the replacement service). The prod service is force-disabled.

```nix
nixosConfigurations.damsac-dev = nixpkgs.lib.nixosSystem {
  modules = [
    disko.nixosModules.disko
    home-manager.nixosModules.home-manager
    self.nixosModules.default  # needed for option definitions
    self.nixosModules.dev
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      nixpkgs.overlays = [ overlay claude-code.overlays.default ];
      # Disable prod service, enable dev service
      services.damsac-studio.enable = lib.mkForce false;
      services.damsac-studio-dev = {
        enable = true;
        port = 8080;
        dataDir = "/var/lib/damsac-studio";
        apiKeys = [ "sk_murmur:murmur-ios" ];
        dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
      };
    }
    ./disko-config.nix
    ./configuration.nix
  ];
};
```

Note: `self.nixosModules.default` (prod) is imported so `services.damsac-studio` options exist. Its config is wrapped in `lib.mkIf cfg.enable`, so with `enable = lib.mkForce false`, no prod systemd service is created. The dev module's service (also named `damsac-studio` in systemd) is the only one that runs.

- [ ] **Step 5: Verify flake evaluates**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: No evaluation errors

- [ ] **Step 6: Commit**

```bash
git add flake.nix configuration.nix
git commit -m "feat: add damsac-dev config, move service settings to per-configuration flake modules"
```

---

### Task 8: Create .claude/commands/ship.md — Claude-assisted ship workflow

**Files:**
- Create: `.claude/commands/ship.md`

- [ ] **Step 1: Create .claude/commands directory**

```bash
mkdir -p .claude/commands
```

- [ ] **Step 2: Write .claude/commands/ship.md**

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add .claude/commands/ship.md
git commit -m "feat: add /ship slash command for Claude-assisted deploy workflow"
```

---

### Task 9: Update deploy.sh and provision.sh for new flake shape

**Files:**
- Modify: `scripts/deploy.sh`
- Modify: `scripts/provision.sh`

- [ ] **Step 1: Simplify deploy.sh**

The script now serves as a remote deploy from a laptop (rsync + rebuild), but the rebuild target needs to reference the correct config. Update the rsync destination and rebuild command:

Replace the rsync target path from `/etc/nixos/` to `/srv/damsac/damsac-studio/`:

```bash
rsync -az --delete \
  --exclude='.git' \
  --exclude='infra/' \
  --exclude='keys/deploy' \
  --exclude='sdk/' \
  --exclude='docs/' \
  --exclude='.claude/' \
  -e "ssh $SSH_OPTS" \
  "$PROJECT_DIR/" "root@${HOST}:/srv/damsac/damsac-studio/"
```

Update the rebuild command:

```bash
ssh $SSH_OPTS "root@${HOST}" "cd /srv/damsac/damsac-studio && nixos-rebuild switch --flake .#damsac"
```

- [ ] **Step 2: Update provision.sh post-install instructions**

Update the "Next steps" output at the end of `provision.sh` to reflect the new workflow:

```bash
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
```

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy.sh scripts/provision.sh
git commit -m "feat: update deploy/provision scripts for shared dev server model"
```

---

### Task 10: Update CLAUDE.md with new server commands and workflow

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add server development section to CLAUDE.md**

Add after the existing "## Commands" section, a new subsection:

```markdown
### Server Development (SSH into VPS)
nrs                            # Rebuild prod (nixos-rebuild switch)
nrsd                           # Rebuild dev mode (air hot reload)
nrt                            # Test rebuild (nixos-rebuild test)
dw <user>                      # Watch teammate's tmux session (read-only)
dp                             # Join/create shared pair session
/ship                          # Claude-assisted: review, commit, push, rebuild
```

- [ ] **Step 2: Add dev/prod mode explanation to Architecture section**

Add to the Architecture section:

```markdown
- `module-dev.nix` — Dev mode service (air hot reload, relaxed hardening)
- `modules/` — NixOS modules (users, workspace, tmux, home-manager) — auto-imported by configuration.nix
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add server dev commands and module layout to CLAUDE.md"
```

---

### Task 11: End-to-end verification

**Files:** None (verification only)

- [ ] **Step 1: Verify full flake evaluation for prod config**

Run: `nix flake check --no-build 2>&1 | head -30`
Expected: No evaluation errors for `nixosConfigurations.damsac`

- [ ] **Step 2: Verify full flake evaluation for dev config**

Run: `nix eval .#nixosConfigurations.damsac-dev.config.system.build.toplevel --raw 2>&1 | head -5`
Expected: A Nix store path (means it evaluates successfully)

- [ ] **Step 3: Verify both configs define expected services**

Prod should have `damsac-studio` service enabled, dev should have `damsac-studio-dev` enabled:

```bash
nix eval .#nixosConfigurations.damsac.config.services.damsac-studio.enable 2>&1
# Expected: true

nix eval .#nixosConfigurations.damsac-dev.config.services.damsac-studio-dev.enable 2>&1
# Expected: true
```

- [ ] **Step 4: Verify Home Manager users are configured**

```bash
nix eval .#nixosConfigurations.damsac.config.home-manager.users --apply 'x: builtins.attrNames x' 2>&1
# Expected: [ "gudnuf" "isaac" ]
```

- [ ] **Step 5: Verify modules are being imported**

```bash
ls modules/*.nix
# Expected: home.nix  tmux.nix  users.nix  workspace.nix
```

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end verification"
```
