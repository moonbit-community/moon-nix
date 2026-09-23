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
  # Fine-grained, per-package builders (the crate2nix/cargo2nix analogue): an
  # external planner emits one call per package, wiring deps through derivation
  # outputs. Toolchain-agnostic — the caller passes `toolchain`.
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
in
{
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
