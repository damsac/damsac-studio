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
    ];

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
