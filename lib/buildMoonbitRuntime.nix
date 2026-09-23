# Compile the MoonBit native runtime sources (`lib/runtime/*.c`) into
# `runtime.o`, once per native executable. The C compiler comes from `stdenv`
# (`$CC` — the nixpkgs cc-wrapper, which resolves crt/libc correctly), the sources
# and headers from the `toolchain`.
#
#   moon2nix.buildMoonbitRuntime { toolchain = …; }   # → $out/runtime.o
{ stdenv }:
{
  pname ? "moonbit-runtime",
  toolchain,
}:
stdenv.mkDerivation {
  name = pname;
  dontUnpack = true;
  phases = [ "buildPhase" ];
  buildPhase = ''
    runHook preBuild
    mkdir -p $out
    export HOME=$TMPDIR
    for source in ${toolchain}/lib/runtime/*.c; do
      $CC -o "$(basename "$source" .c).o" -I${toolchain}/include -g -c \
        -fwrapv -fno-strict-aliasing -O2 \
        -DMOONBIT_ALLOW_STACKTRACE -DMOONBIT_USE_SIMDUTF "$source"
    done
    $CC -r -o $out/runtime.o ./*.o
    runHook postBuild
  '';
}
