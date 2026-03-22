{
  description = "damsac-studio — self-hosted analytics for Murmur";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mercury = {
      url = "github:gudnuf/mercury";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, disko, claude-code, home-manager, mercury }:
    let
      lib = nixpkgs.lib;

      mkPackage = pkgs: pkgs.buildGoModule {
        pname = "damsac-studio";
        version = "0.1.0";
        src = ./api;

        vendorHash = null;

        postInstall = ''
          mv $out/bin/api $out/bin/damsac-studio
        '';

        meta = {
          description = "Self-hosted analytics server for Murmur";
          mainProgram = "damsac-studio";
        };
      };

      overlay = final: prev: {
        damsac-studio = mkPackage final;
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = mkPackage pkgs;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            sqlite
            air
            gopls
            hcloud
            jq
          ];

          shellHook = ''
            export PATH="$PWD/scripts:$PATH"
            echo "damsac-studio dev shell"
            echo "  go $(go version | awk '{print $3}')"
            echo "  sqlite3 $(sqlite3 --version | awk '{print $1}')"
            echo "  scripts on PATH (damsac-ssh, damsac-status, etc.)"
          '';
        };
      }
    ) // {
      overlays.default = overlay;
      nixosModules.default = import ./module.nix;
      nixosModules.dev = import ./module-dev.nix;

      nixosConfigurations.damsac = nixpkgs.lib.nixosSystem {
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          self.nixosModules.default
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            nixpkgs.overlays = [
              overlay
              claude-code.overlays.default
              (final: prev: { mercury = mercury.packages.${final.system}.default; })
            ];
            nixpkgs.config.allowUnfreePredicate = pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
            services.damsac-studio = {
              enable = true;
              port = 8080;
              dataDir = "/var/lib/damsac-studio";
              apiKeys = [ "sk_murmur:murmur-ios" ];
              dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
              secureCookie = false;
            };
          }
          ./disko-config.nix
          ./configuration.nix
        ];
      };

      nixosConfigurations.damsac-dev = nixpkgs.lib.nixosSystem {
        modules = [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          self.nixosModules.default
          self.nixosModules.dev
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            nixpkgs.overlays = [
              overlay
              claude-code.overlays.default
              (final: prev: { mercury = mercury.packages.${final.system}.default; })
            ];
            nixpkgs.config.allowUnfreePredicate = pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
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
    };
}
