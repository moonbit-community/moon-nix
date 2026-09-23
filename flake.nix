{
  description = "Nix project and package builders for MoonBit";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    moonbit-overlay = {
      url = "github:moonbit-community/moonbit-overlay/fix/modernize-moonbit-tests";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      moonbit-overlay,
    }:
    let
      forEachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    {
      lib.mkMoon2Nix = import ./default.nix;
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          toolchain = moonbit-overlay.packages.${system}.latest;
        in
        rec {
          moon2nix = import ./generator.nix { inherit pkgs toolchain; };
          default = moon2nix;
        }
      );
      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          formatting = pkgs.runCommand "moon2nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
        }
      );
    };
}
