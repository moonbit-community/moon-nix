# `cc`-link a native MoonBit program: the `link-core`-emitted `.c` + the compiled
# runtime + any C-stub archives + the toolchain's simdutf objects + libbacktrace
# (+ libm) into the final executable. The companion to [linkMoonbitProgram] (with
# `target = "native"`) and [buildMoonbitRuntime].
#
#   moon2nix.makeMoonbitExecutable {
#     pname    = "a_b";
#     programC = cDrv;        # linkMoonbitProgram { target = "native"; } → $out/a_b.c
#     runtime  = runtimeDrv;  # buildMoonbitRuntime → $out/runtime.o
#     stubArchives = [ ];     # [ { drv = …; name = "lib<pkg>.a"; } ] (C-FFI packages)
#     pkgConfig = [ "zlib" ]; # native deps from `options("pkg-config")` — `--libs`
#     buildInputs = [ pkgs.zlib ];  # the corresponding nixpkgs libraries
#     toolchain = …;
#   }
#   # → $out/a_b   (an executable)
{
  lib,
  stdenv,
  pkg-config,
}:
{
  pname,
  programC,
  runtime,
  stubArchives ? [ ],
  # `options("pkg-config")` native deps: the module names whose `--libs` join the
  # link, plus the nixpkgs libraries that provide them (so pkg-config — run IN the
  # sandbox via the setup hook's PKG_CONFIG_PATH — resolves them purely). Both
  # default empty ⇒ the link is unchanged (backward-compatible).
  pkgConfig ? [ ],
  buildInputs ? [ ],
  toolchain,
}:
let
  stubArgs = map (a: "${a.drv}/${a.name}") stubArchives;
  pkgCfgLibs = lib.optionalString (
    pkgConfig != [ ]
  ) "$(pkg-config --libs ${lib.escapeShellArgs pkgConfig})";
  tailObjs = "${toolchain}/lib/moonbit_simdutf.o ${toolchain}/lib/simdutf.o -lm ${toolchain}/lib/libbacktrace.a";
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
    $CC -o $out/${pname} -I${toolchain}/include -g -fwrapv -fno-strict-aliasing -Og \
      ${programC}/${pname}.c ${runtime}/runtime.o \
      ${lib.escapeShellArgs stubArgs} \
      ${pkgCfgLibs} \
      ${tailObjs}
    runHook postBuild
  '';
}
