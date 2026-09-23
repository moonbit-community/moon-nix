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
          toolchain = moonbit-overlay.packages.${system}.latest;
          platform = self.lib.mkMoon2Nix { inherit pkgs toolchain; };
          native = import ./test-native.nix { inherit pkgs toolchain platform; };
          wasm = import ./test-fine-grained.nix { inherit pkgs toolchain platform; };
          plannedWasm = platform.buildPlan {
            plan = import ./examples/wasm-plan.nix;
            sources = [
              ./examples/hello
              ./examples/support
            ];
          };
          plannedNative = platform.buildPlan {
            plan = import ./examples/native-linux-plan.nix;
            sources = [
              ./examples/hello
              ./examples/support
            ];
          };
        in
        {
          formatting = pkgs.runCommand "moon2nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
          plannedWasm = pkgs.runCommand "moon2nix-test-planned-wasm" { } ''
            test "$(${toolchain}/bin/moonrun ${plannedWasm}/bin/main.wasm)" = "42"
            touch $out
          '';
          generator =
            pkgs.runCommand "moon2nix-test-generator"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.nix
                ];
              }
              ''
                python ${./tests/generator.py} ${
                  self.packages.${system}.moon2nix
                }/bin/moon2nix ${toolchain} ${./examples}
                touch $out
              '';
          native = pkgs.runCommand "moon2nix-test-native" { } ''
            test "$(${native}/hello_main)" = "hi from native makeMoonbitExecutable"
            touch $out
          '';
          wasm = pkgs.runCommand "moon2nix-test-wasm" { } ''
            test "$(${toolchain}/bin/moonrun ${wasm}/hello_main.wasm)" = "hi from buildMoonbitPackage framework"
            touch $out
          '';
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          plannedNative = pkgs.runCommand "moon2nix-test-planned-native" { } ''
            test "$(${plannedNative}/bin/main.exe)" = "42"
            touch $out
          '';
        }
      );
    };
}
