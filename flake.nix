{
  description = "A Flake for testing vxlan over wireguard";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };
  outputs = { self, nixpkgs, flake-parts }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      flake = {
        overlays.default = final: prev: {};
        nixosModules.default = { pkgs, lib, config, ... }: {
          nixpkgs.overlays = [ self.overlays.default ];
        };
      };
      perSystem = { config, self', inputs', pkgs, lib, system, ... }: {
        checks = {
          vxlan-nix = pkgs.callPackage ./vmtest.nix { nixosModule = self.nixosModules.default; };
        };
      };
    };
}

