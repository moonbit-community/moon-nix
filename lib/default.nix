# Project and package builders; the caller supplies a complete toolchain.
{ pkgs, toolchain }:
let
  inherit (pkgs)
    lib
    fetchurl
    stdenv
    symlinkJoin
    makeWrapper
    zig
    clang
    pkg-config
    ;
  fetchMoonPackage = import ./fetchMoonPackage.nix {
    inherit fetchurl;
  };

  parseMoonIndex = import ./parseMoonIndex.nix {
    inherit lib;
  };

  listAllDependencies = import ./listAllDependencies.nix {
    inherit parseMoonIndex lib;
  };

  buildCachedRegistry = import ./buildCachedRegistry.nix {
    inherit
      fetchMoonPackage
      listAllDependencies
      lib
      stdenv
      ;
  };

  bundleWithRegistry = import ./bundleWithRegistry.nix {
    inherit
      symlinkJoin
      makeWrapper
      toolchain
      ;
  };

  buildMoonPackage = import ./buildMoonPackage.nix {
    inherit
      lib
      stdenv
      buildCachedRegistry
      bundleWithRegistry
      ;
  };

  # Fine-grained, per-package builders (the crate2nix/cargo2nix analogue): an
  # external planner emits one call per package, wiring deps through derivation
  # outputs. Toolchain-agnostic — the caller passes `toolchain`.
  buildMoonbitPackage = import ./buildMoonbitPackage.nix { inherit lib stdenv; };
  buildMoonbitInterface = import ./buildMoonbitInterface.nix { inherit lib stdenv; };
  runMoonbitPrebuild = import ./runMoonbitPrebuild.nix { inherit lib stdenv; };
  linkMoonbitProgram = import ./linkMoonbitProgram.nix { inherit lib stdenv; };
  buildMoonbitRuntime = import ./buildMoonbitRuntime.nix { inherit stdenv zig; };
  makeMoonbitExecutable = import ./makeMoonbitExecutable.nix {
    inherit
      lib
      stdenv
      pkg-config
      zig
      ;
  };
  buildMoonbitCStub = import ./buildMoonbitCStub.nix {
    inherit
      lib
      stdenv
      pkg-config
      zig
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
  buildPlan = import ./buildPlan.nix { inherit pkgs toolchain; };
  inherit
    buildCachedRegistry
    bundleWithRegistry
    buildMoonPackage
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
