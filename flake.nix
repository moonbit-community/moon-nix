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
      lib = {
        mkMoonNix = import ./default.nix;
        mkMoon2Nix = self.lib.mkMoonNix; # Compatibility for existing flakes.
      };
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pure = import ./tests/pure {
            inherit pkgs;
            toolchain = moonbit-overlay.packages.${system}.latest;
          };
        in
        {
          pure-evaluation = pure.evaluation;
          pure-wasm = pure.wasm;
          pure-js = pure.js;
          pure-native = pure.native;
          c-stub = pure.c-stub;
          virtual = pure.virtual;
          workspace-prebuild = pure.workspace-prebuild;
          generated-c = pure.generated-c;
          registry-source = pure.registry-source;
          formatting = pkgs.runCommand "moon-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
        }
      );
    };
}
