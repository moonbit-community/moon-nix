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
      lib.mkMoonNix = import ./default.nix;
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);
      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          toolchain = moonbit-overlay.packages.${system}.latest;
        in
        rec {
          generator = import ./generator.nix { inherit pkgs toolchain; };
          default = generator;
        }
      );
      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          toolchain = moonbit-overlay.packages.${system}.latest;
          platform = self.lib.mkMoonNix { inherit pkgs toolchain; };
          native = import ./test-native.nix { inherit pkgs toolchain platform; };
          wasm = import ./test-fine-grained.nix { inherit pkgs toolchain platform; };
          plannedWasm = platform.buildPlan {
            plan = ./examples/wasm-plan.json;
            sources = [
              ./examples/hello
              ./examples/support
            ];
          };
          plannedNative = platform.buildPlan {
            plan = ./examples/native-linux-plan.json;
            sources = [
              ./examples/hello
              ./examples/support
            ];
          };
          project = platform.buildMoonPackage {
            name = "moon-nix-with-deps";
            src = ./test/with_deps;
            moonMod = {
              name = "moonbit-community/overlay_test";
              version = "0.1.0";
              deps."gmlewis/base64" = "0.16.12";
            };
            moonRegistryIndex = ./test/registry;
          };
        in
        {
          formatting = pkgs.runCommand "moon-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
          plannedWasm = pkgs.runCommand "moon-nix-test-planned-wasm" { } ''
            test "$(${toolchain}/bin/moonrun ${plannedWasm}/bin/main.wasm)" = "42"
            touch $out
          '';
          generator = pkgs.runCommand "moon-nix-test-generator" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            python ${./tests/generator.py} ${
              self.packages.${system}.generator
            }/bin/moon-nix-plan ${toolchain} ${./examples}
            touch $out
          '';
          native = pkgs.runCommand "moon-nix-test-native" { } ''
            test "$(${native}/hello_main)" = "hi from native makeMoonbitExecutable"
            touch $out
          '';
          wasm = pkgs.runCommand "moon-nix-test-wasm" { } ''
            test "$(${toolchain}/bin/moonrun ${wasm}/hello_main.wasm)" = "hi from buildMoonbitPackage framework"
            touch $out
          '';
          project = pkgs.runCommand "moon-nix-test-project" { } ''
            expected=$(printf 'aGk=\n89')
            test "$(${project}/bin/main)" = "$expected"
            touch $out
          '';
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          plannedNative = pkgs.runCommand "moon-nix-test-planned-native" { } ''
            test "$(${plannedNative}/bin/main.exe)" = "42"
            touch $out
          '';
        }
      );
    };
}
