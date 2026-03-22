{ pkgs, ... }:

let
  # ── Agent launcher script ──────────────────────────────────────────
  # Creates a Discord state dir for a named agent and launches Claude.
  # Usage:
  #   launch-agent alchemist                     # No Discord channel
  #   launch-agent alchemist <channel-id>        # With Discord channel
  #   launch-agent keeper:murmur <channel-id>    # Keeper with channel
  #
  # State dirs live at ~/.claude/channels/discord-<agent-name>/
  # Bot token is copied from the default Discord state dir.
  launchAgent = pkgs.writeShellScriptBin "launch-agent" ''
    set -euo pipefail

    if [[ $# -lt 1 ]]; then
      echo "Usage: launch-agent <agent-name> [discord-channel-id ...]"
      echo ""
      echo "Examples:"
      echo "  launch-agent alchemist 123456789"
      echo "  launch-agent keeper:murmur 123456789 987654321"
      echo "  launch-agent worker:auth"
      echo ""
      echo "Agent name becomes the Mercury identity."
      echo "Discord channel IDs are opted in with requireMention=false."
      exit 1
    fi

    AGENT_NAME="$1"
    shift
    CHANNEL_IDS=("$@")

    # Sanitize agent name for directory (replace : with -)
    DIR_NAME="''${AGENT_NAME//:/-}"
    STATE_DIR="$HOME/.claude/channels/discord-$DIR_NAME"
    DEFAULT_STATE_DIR="$HOME/.claude/channels/discord"

    # Create state dir
    mkdir -p "$STATE_DIR"

    # Copy bot token from default state dir if not already present
    if [[ ! -f "$STATE_DIR/.env" ]]; then
      if [[ -f "$DEFAULT_STATE_DIR/.env" ]]; then
        cp "$DEFAULT_STATE_DIR/.env" "$STATE_DIR/.env"
        chmod 600 "$STATE_DIR/.env"
        echo "Copied bot token to $STATE_DIR/.env"
      else
        echo "Error: No bot token found at $DEFAULT_STATE_DIR/.env"
        echo "Run /discord:configure in a Claude session first."
        exit 1
      fi
    fi

    # Build access.json with opted-in channels
    GROUPS_JSON="{"
    FIRST=true
    for CID in "''${CHANNEL_IDS[@]}"; do
      if [[ "$FIRST" == "true" ]]; then
        FIRST=false
      else
        GROUPS_JSON="$GROUPS_JSON,"
      fi
      GROUPS_JSON="$GROUPS_JSON \"$CID\": { \"requireMention\": false, \"allowFrom\": [] }"
    done
    GROUPS_JSON="$GROUPS_JSON }"

    # Write access.json (preserve allowFrom from default if it exists)
    ALLOW_FROM="[]"
    if [[ -f "$DEFAULT_STATE_DIR/access.json" ]]; then
      ALLOW_FROM=$(${pkgs.jq}/bin/jq -c '.allowFrom // []' "$DEFAULT_STATE_DIR/access.json")
    fi

    ${pkgs.jq}/bin/jq -n \
      --argjson groups "$GROUPS_JSON" \
      --argjson allowFrom "$ALLOW_FROM" \
      '{
        dmPolicy: "allowlist",
        allowFrom: $allowFrom,
        groups: $groups,
        pending: {}
      }' > "$STATE_DIR/access.json"

    echo "Agent: $AGENT_NAME"
    echo "State: $STATE_DIR"
    echo "Channels: ''${CHANNEL_IDS[*]:-none}"
    echo ""

    # Subscribe to Mercury channels
    mercury subscribe --as "$AGENT_NAME" --channel status 2>/dev/null || true
    if [[ "$AGENT_NAME" == keeper:* ]]; then
      mercury subscribe --as "$AGENT_NAME" --channel "studio" 2>/dev/null || true
      mercury subscribe --as "$AGENT_NAME" --channel "$AGENT_NAME" 2>/dev/null || true
    elif [[ "$AGENT_NAME" == "alchemist" ]]; then
      mercury subscribe --as "$AGENT_NAME" --channel "studio" 2>/dev/null || true
    elif [[ "$AGENT_NAME" == worker:* ]]; then
      mercury subscribe --as "$AGENT_NAME" --channel "workers" 2>/dev/null || true
    fi
    mercury send --as "$AGENT_NAME" --to status "$AGENT_NAME online" 2>/dev/null || true

    # Launch Claude with Mercury + optional Discord
    BASE_ARGS="--dangerously-skip-permissions --channels server:mercury"
    if [[ ''${#CHANNEL_IDS[@]} -gt 0 ]]; then
      DISCORD_STATE_DIR="$STATE_DIR" MERCURY_IDENTITY="$AGENT_NAME" exec claude $BASE_ARGS --channels plugin:discord@claude-plugins-official
    else
      MERCURY_IDENTITY="$AGENT_NAME" exec claude $BASE_ARGS
    fi
  '';

  # Shared Home Manager config applied to all damsac users
  sharedHome = { username, realName, email }: {
    home.stateVersion = "24.11";
    home.username = username;
    home.homeDirectory = "/home/${username}";

    home.packages = [
      launchAgent
    ] ++ (with pkgs; [
      # AI tools
      claude-code
      bun
      mercury

      # Version control
      jujutsu

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
    ]);

    programs.git = {
      enable = true;
      settings.user.name = realName;
      settings.user.email = email;
    };

    # jj (Jujutsu) config — user identity + git colocated defaults
    home.file.".jjconfig.toml".text = ''
      [user]
      name = "${realName}"
      email = "${email}"

      [ui]
      default-command = "log"
      diff-editor = ":builtin"
    '';

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
        cdw = "cd /srv/damsac/$USER";
        cdd = "cd /srv/damsac/damsac-studio";
        # Mercury shortcuts
        ms = "mercury send";
        mr = "mercury read";
        ml = "mercury log";
        mc = "mercury channels";
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
