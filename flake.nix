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
  };

  outputs = { self, nixpkgs, flake-utils, disko, claude-code, home-manager }:
    let
      mkPackage = pkgs: pkgs.buildGoModule {
        pname = "damsac-studio";
        version = "0.1.0";
        src = ./api;

        vendorHash = "sha256-JlQWPfcNpIgag1LHDcvz1wlxo/RcdN02J3zKXFd1tvc=";

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
    };
}
