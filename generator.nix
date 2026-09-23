{ pkgs, toolchain }:
let
  x = pkgs.fetchFromGitHub {
    owner = "moonbitlang";
    repo = "x";
    rev = "b4a4017757179e1290d3e2b939e7e7128082639e";
    hash = "sha256-U9ScbAZsMAkhNrO1ZCy8cKajpHpp/5aUMhmmnNeJeLc=";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "moon2nix";
  version = "0.1.0";
  src = pkgs.lib.cleanSourceWith {
    src = ./generator;
    filter =
      path: type:
      pkgs.lib.cleanSourceFilter path type
      && !(builtins.elem (builtins.baseNameOf path) [
        "_build"
        ".mooncakes"
        "x"
      ]);
  };
  nativeBuildInputs = [ toolchain ];
  buildPhase = ''
    runHook preBuild
    ln -s ${x} x
    export MOON_HOME=$TMPDIR/moon-home
    mkdir -p "$MOON_HOME"
    moon build src/main --target native --release
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 _build/native/release/build/moon/main/main.exe $out/bin/moon2nix
    runHook postInstall
  '';
  meta = {
    description = "Export MoonBit build plans for Nix";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "moon2nix";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
  };
}
