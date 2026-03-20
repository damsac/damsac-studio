{ config, lib, pkgs, ... }:

let
  cfg = config.services.damsac-studio;
in
{
  options.services.damsac-studio = {
    enable = lib.mkEnableOption "damsac-studio analytics server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for the damsac-studio HTTP server to listen on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/damsac-studio";
      description = "Directory for the SQLite database file.";
    };

    apiKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sk_murmur:murmur-ios" ];
      description = ''
        List of API keys in "key:app_id" format.
        Each key authorizes ingest requests for the associated app ID.
      '';
    };

    dashboardPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/damsac-dashboard-pw";
      description = ''
        Path to a file containing the dashboard password.
        Compatible with sops-nix and agenix secret management.
      '';
    };

    package = lib.mkPackageOption pkgs "damsac-studio" { };

    secureCookie = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to set the Secure flag on dashboard session cookies. Defaults to true for production (HTTPS).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the firewall for the damsac-studio port.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dashboardPasswordFile != null;
        message = "services.damsac-studio.dashboardPasswordFile must be set to a file path containing the dashboard password.";
      }
      {
        assertion = cfg.apiKeys != [ ];
        message = "services.damsac-studio.apiKeys must contain at least one \"key:app_id\" entry.";
      }
    ];

    systemd.services.damsac-studio = {
      description = "damsac-studio analytics server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        PORT = toString cfg.port;
        DATA_DIR = cfg.dataDir;
        API_KEYS = lib.concatStringsSep "," cfg.apiKeys;
        DASHBOARD_SECURE_COOKIE = if cfg.secureCookie then "true" else "false";
      } // lib.optionalAttrs (cfg.dashboardPasswordFile != null) {
        DASHBOARD_PASSWORD_FILE = toString cfg.dashboardPasswordFile;
      };

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        DynamicUser = true;
        StateDirectory = "damsac-studio";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir ];
      } // lib.optionalAttrs (cfg.dashboardPasswordFile != null) {
        ReadOnlyPaths = [ cfg.dashboardPasswordFile ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
