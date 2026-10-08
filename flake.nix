{
  description = "Nix packaging of the Probo device agent";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: {
        probo-agent = final.callPackage ./pkgs/probo-agent/package.nix { };
      };

      packages = forAllSystems (pkgs: rec {
        probo-agent = pkgs.callPackage ./pkgs/probo-agent/package.nix { };
        default = probo-agent;
      });

      nixosModules = rec {
        probo-agent =
          { lib, pkgs, ... }:
          {
            imports = [ ./nixos/probo-agent.nix ];
            services.probo-agent.package = lib.mkDefault (pkgs.callPackage ./pkgs/probo-agent/package.nix { });
          };
        default = probo-agent;
      };

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) probo-agent;
        nixos = pkgs.testers.runNixOSTest (import ./nixos/test.nix self);
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
