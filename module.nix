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

    claudeCode.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to configure Claude Code MCP integration for this service.";
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

    # Configure Claude Code MCP client to connect to this service.
    # Merges into ~/.claude.json so existing user config is preserved.
    home-manager.sharedModules = lib.mkIf cfg.claudeCode.enable (let
      apiKey = builtins.head (builtins.map (k: builtins.head (lib.splitString ":" k)) cfg.apiKeys);
      mcpConfig = builtins.toJSON {
        mcpServers.damsac-studio = {
          type = "http";
          url = "http://localhost:${toString cfg.port}/mcp";
          headers."X-API-Key" = apiKey;
        };
      };
    in [{
      home.activation.damsac-mcp = ''
        CLAUDE_JSON="$HOME/.claude.json"
        MCP_FRAGMENT='${mcpConfig}'
        if [ -f "$CLAUDE_JSON" ]; then
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CLAUDE_JSON" <(echo "$MCP_FRAGMENT") > "$CLAUDE_JSON.tmp" \
            && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        else
          echo "$MCP_FRAGMENT" > "$CLAUDE_JSON"
        fi
      '';
    }]);
  };
}
