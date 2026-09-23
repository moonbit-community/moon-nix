# Compile one C-FFI stub (`options("native-stub")`) into a `.o`, for the native
# backend. `$CC` is stdenv's cc-wrapper; `moonbit.h` comes from the toolchain.
#
#   moon2nix.buildMoonbitCStub { pname = "a_b_0"; stub = ./a/b/stub.c; toolchain = …; }
#   # → $out/a_b_0.o
{
  lib,
  stdenv,
  pkg-config,
}:
{
  pname,
  stub,
  # `options("pkg-config")` native deps: the module names whose `--cflags` (header
  # search paths) join this stub's compile, plus the nixpkgs libraries providing
  # them. Both default empty ⇒ the compile is unchanged (backward-compatible).
  pkgConfig ? [ ],
  buildInputs ? [ ],
  toolchain,
}:
let
  pkgCfgCflags = lib.optionalString (
    pkgConfig != [ ]
  ) "$(pkg-config --cflags ${lib.escapeShellArgs pkgConfig})";
in
stdenv.mkDerivation {
  name = pname;
  dontUnpack = true;
  nativeBuildInputs = lib.optional (pkgConfig != [ ]) pkg-config;
  inherit buildInputs;
  phases = [ "buildPhase" ];
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    export HOME=$TMPDIR
    $CC -o $out/${pname}.o -I${toolchain}/include -g -c -fwrapv -fno-strict-aliasing \
      -Og ${pkgCfgCflags} ${stub}
    runHook postBuild
  '';
}
