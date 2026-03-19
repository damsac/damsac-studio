{
  description = "damsac-studio — self-hosted analytics for Murmur";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.buildGoModule {
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

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            sqlite
            air
            gopls
          ];

          shellHook = ''
            echo "damsac-studio dev shell"
            echo "  go $(go version | awk '{print $3}')"
            echo "  sqlite3 $(sqlite3 --version | awk '{print $1}')"
          '';
        };
      }
    ) // {
      nixosModules.default = import ./module.nix;
    };
}
