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

      path = [ pkgs.go pkgs.git pkgs.gcc ];

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
