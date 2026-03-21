{ pkgs, ... }:

let
  SOCKET = "/run/tmux-damsac/shared";

  # dw <user> — switch to a teammate's tmux session (read-only if outside tmux, switch-client if inside)
  damsac-watch = pkgs.writeShellScriptBin "dw" ''
    SOCKET="${SOCKET}"
    if [ -z "$1" ]; then
      echo "usage: dw <username>"
      echo ""
      echo "Available sessions:"
      ${pkgs.tmux}/bin/tmux -S "$SOCKET" list-sessions 2>/dev/null || echo "  (none)"
      exit 1
    fi
    if [ -n "$TMUX" ]; then
      exec ${pkgs.tmux}/bin/tmux -S "$SOCKET" switch-client -t "$1"
    else
      exec ${pkgs.tmux}/bin/tmux -S "$SOCKET" attach -t "$1" -r
    fi
  '';

  # dp — switch to (or create) the shared pair session
  damsac-pair = pkgs.writeShellScriptBin "dp" ''
    SOCKET="${SOCKET}"
    if ! ${pkgs.tmux}/bin/tmux -S "$SOCKET" has -t pair 2>/dev/null; then
      ${pkgs.tmux}/bin/tmux -S "$SOCKET" new-session -d -s pair -c /srv/damsac
    fi
    if [ -n "$TMUX" ]; then
      exec ${pkgs.tmux}/bin/tmux -S "$SOCKET" switch-client -t pair
    else
      exec ${pkgs.tmux}/bin/tmux -S "$SOCKET" attach -t pair
    fi
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
