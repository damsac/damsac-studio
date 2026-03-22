{ pkgs, lib, ... }:

let
  feedSrc = builtins.path {
    path = ../tools/mercury-discord-feed;
    name = "mercury-discord-feed";
  };
in
{
  # Copy feed source to a stable location on activation
  system.activationScripts.mercury-discord-feed = lib.stringAfter [ "etc" ] ''
    mkdir -p /var/lib/mercury-discord-feed
    install -m 0644 ${feedSrc}/index.ts /var/lib/mercury-discord-feed/index.ts
    install -m 0644 ${feedSrc}/package.json /var/lib/mercury-discord-feed/package.json
    chown -R gudnuf:users /var/lib/mercury-discord-feed
  '';

  # Mercury Discord feed systemd service
  systemd.services.mercury-discord-feed = {
    description = "Mercury to Discord live feed";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "gudnuf";
      Group = "users";
      WorkingDirectory = "/var/lib/mercury-discord-feed";
      ExecStart = "${pkgs.bun}/bin/bun run index.ts";
      Restart = "always";
      RestartSec = 5;
      EnvironmentFile = [
        "/home/gudnuf/.claude/channels/discord/.env"
      ];
      Environment = [
        "DISCORD_FEED_CHANNEL_ID=1485368650201301062"
        "MERCURY_DB_PATH=/home/gudnuf/.local/share/mercury/mercury.db"
        "CURSOR_FILE_PATH=/home/gudnuf/.local/share/mercury/discord-feed-cursor"
      ];
    };
  };
}
