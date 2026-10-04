# Build-plan and package builders; the caller supplies a complete toolchain.
{ pkgs, toolchain }:
let
  inherit (pkgs)
    lib
    stdenv
    zig
    clang
    pkg-config
    ;
  # Low-level package builders remain available for custom derivation graphs.
  # The caller supplies the toolchain.
  buildMoonbitPackage = import ./buildMoonbitPackage.nix { inherit lib stdenv; };
  buildMoonbitInterface = import ./buildMoonbitInterface.nix { inherit lib stdenv; };
  runMoonbitPrebuild = import ./runMoonbitPrebuild.nix { inherit lib stdenv; };
  linkMoonbitProgram = import ./linkMoonbitProgram.nix { inherit lib stdenv; };
  buildMoonbitRuntime = import ./buildMoonbitRuntime.nix { inherit stdenv; };
  makeMoonbitExecutable = import ./makeMoonbitExecutable.nix {
    inherit
      lib
      stdenv
      pkg-config
      ;
  };
  buildMoonbitCStub = import ./buildMoonbitCStub.nix {
    inherit
      lib
      stdenv
      pkg-config
      ;
  };
  buildMoonbitZigStub = import ./buildMoonbitZigStub.nix {
    inherit
      lib
      stdenv
      zig
      pkg-config
      ;
  };
  translateMoonbitCHeader = import ./translateMoonbitCHeader.nix { inherit lib stdenv zig; };
  buildMoonbitObjcStub = import ./buildMoonbitObjcStub.nix { inherit stdenv clang; };
  archiveMoonbitStubs = import ./archiveMoonbitStubs.nix { inherit lib stdenv; };
  manifest = import ./pure/manifest.nix { inherit lib; };
  resolver = import ./pure/resolve.nix { inherit lib manifest; };
  pureBuilders = {
    buildAction = import ./buildAction.nix { inherit pkgs toolchain; };
    finishBuild = import ./finishBuild.nix { inherit pkgs; };
  };
in
{
  buildProject = import ./pure/buildProject.nix {
    inherit
      pkgs
      toolchain
      manifest
      resolver
      ;
    builders = pureBuilders;
  };
  parseManifest = kind: text: manifest.normalize (manifest.parseDSL kind text);
  resolveDependencies = resolver.resolve;
  buildAction = import ./buildAction.nix { inherit pkgs toolchain; };
  finishBuild = import ./finishBuild.nix { inherit pkgs; };
  inherit
    buildMoonbitPackage
    buildMoonbitInterface
    runMoonbitPrebuild
    linkMoonbitProgram
    buildMoonbitRuntime
    makeMoonbitExecutable
    buildMoonbitCStub
    buildMoonbitZigStub
    translateMoonbitCHeader
    buildMoonbitObjcStub
    archiveMoonbitStubs
    ;
}
