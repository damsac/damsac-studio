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
