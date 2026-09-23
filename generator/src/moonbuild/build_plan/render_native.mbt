// Native C-toolchain command rendering: the BuildRuntime / BuildCStub /
// BuildZigStub / ArchiveCStubs / MakeExecutable arms of `render_command`, split
// out of render.mbt to keep the native compiler flags together.
// `render_command` dispatches to these.
// Mirrors the build_plan `actions.mbt` / `actions_native.mbt` split.

///|
/// Native actions already carry an argv vector; Nix provides the compiler in PATH.
fn cc_exec(argv : Array[String]) -> @core.Command {
  @core.Exec(argv~, cwd=None)
}

///|
fn cc_exec_to(argv : Array[String], stdout_path : String) -> @core.Command {
  @core.ExecTo(argv~, stdout=stdout_path)
}

///|
/// `cc`-compile one toolchain runtime source into a `.o`.
fn render_build_runtime(
  out : String,
  cc : String,
  include_dir : String,
  runtime_c : String,
  simdutf : Bool,
) -> @core.Command {
  let argv = [cc, "-o", out, "-I" + include_dir]
  argv.push("-c")
  argv.push("-fwrapv")
  argv.push("-fno-strict-aliasing")
  argv.push("-O2")
  // `simdutf` is decided by the plan so the define and prebuilt objects agree.
  argv.push("-DMOONBIT_ALLOW_STACKTRACE")
  if simdutf {
    argv.push("-DMOONBIT_USE_SIMDUTF")
  }
  argv.push(runtime_c)
  cc_exec(argv)
}

///|
/// `cc`-compile one C stub into a `.o` (the owning package's stub-cc flags
/// already folded into `cc_flags`).
fn render_build_cstub(
  out : String,
  cc : String,
  include_dir : String,
  stub : String,
  cc_flags : Array[String],
) -> @core.Command {
  let has_user_flags = !cc_flags.is_empty()
  let argv = [cc, "-o", out, "-I" + include_dir]
  argv.push("-c")
  argv.push("-fwrapv")
  argv.push("-fno-strict-aliasing")
  if !has_user_flags {
    argv.push("-O2")
  }
  argv.push(stub)
  for f in cc_flags {
    argv.push(f)
  }
  cc_exec(argv)
}

///|
/// Compile one `.zig` stub into a relocatable object via `zig build-obj`. The
/// object slots into the SAME archive + final-link steps as a C stub (it is just
/// another `.o`), so the C/Zig split is invisible downstream. `-I<include_dir>`
/// exposes `moonbit.h`; `-O ReleaseFast` keeps the object free of Zig's safety
/// panic-handler references (which would otherwise be undefined at the cc final
/// link, since the moonbit runtime — not Zig std — provides the symbols). The
/// idiomatic stub passes/returns `Bytes` (`moonbit_bytes_t`, a `[*c]u8`), so no
/// `String` (u16) marshaling is needed. `-lc` declares the libc dependency the
/// stub already has (the moonbit binary links libc) so `std`'s libc-backed
/// pieces — e.g. `std.heap.c_allocator` — pass their compile-time link gate; it
/// only sets the dependency flag, the actual libc link still happens once, in the
/// final executable.
fn render_build_zig_stub(
  out : String,
  zig : String,
  include_dir : String,
  stub : String,
  modules : Array[(String, String)],
  target : String?,
) -> @core.Command {
  // Cross build: `-target <triple>` makes the object match the cross C objects it
  // links with. `None` (native) omits it → zig's host default, unchanged.
  let tgt : Array[String] = match target {
    Some(t) => ["-target", t]
    None => []
  }
  // `-fPIC` so the object links into moonbit's (PIE-by-default on many hosts)
  // final executable without a text-relocation error.
  if modules.is_empty() {
    // Common stub (hand-written `extern` decls): the bare positional-file form.
    return cc_exec(
      [
        zig,
        "build-obj",
        "-femit-bin=" + out,
        "-O",
        "ReleaseFast",
        "-fPIC",
        "-lc",
        ..tgt,
        "-I" + include_dir,
        stub,
      ],
    )
  }
  // The stub `@import`s translate-c'd modules, so use the explicit module form:
  // the bare positional-file form can't carry import deps. Per-module settings
  // (`-O`/`-fPIC`) precede the `-M` args; `--dep <name>` adds `<name>` to the main
  // module's import table, then `-M<name>=<path>` defines it. Validated by spike.
  let argv = [
    zig,
    "build-obj",
    "-femit-bin=" + out,
    "-O",
    "ReleaseFast",
    "-fPIC",
    "-lc",
    ..tgt,
    "-I" + include_dir,
  ]
  for m in modules {
    argv.push("--dep")
    argv.push(m.0)
  }
  argv.push("-Mmain=" + stub)
  for m in modules {
    argv.push("-M" + m.0 + "=" + m.1)
  }
  cc_exec(argv)
}

///|
/// `zig translate-c` one header (in `include_dir`) into a Zig module, capturing
/// stdout (translate-c has no output-file flag) to `out` via `ExecTo`. `-lc` so the
/// header's own `#include <math.h>` etc. resolve against the (zig-provided) libc.
/// On success translate-c writes nothing to stderr, so `out` is the clean `.zig`.
///
/// `-DMOONBIT_NATIVE_NO_SYS_HEADER`: `moonbit.h` pulls in `<arm_neon.h>` on arm64
/// (for its SIMD `v128` type), and zig 0.16's bundled clang resource header
/// `arm_vector_types.h` fails to parse the newer FP8 NEON type (`__mfp8 mfloat8_t`),
/// breaking translate-c on arm64 macОS (Linux x86_64 takes the `<emmintrin.h>`
/// branch and is unaffected). The define takes moonbit.h's plain-struct `v128`
/// fallback instead — translate-c only needs the API decls/macros (e.g.
/// `Moonbit_array_length`), never the real SIMD vector type, so this is safe on
/// every host.
fn render_translate_c(
  out : String,
  zig : String,
  include_dir : String,
  header : String,
) -> @core.Command {
  cc_exec_to(
    [
      zig,
      "translate-c",
      "-lc",
      "-DMOONBIT_NATIVE_NO_SYS_HEADER",
      "-I" + include_dir,
      include_dir + "/" + header,
    ],
    out,
  )
}

///|
/// Compile one Objective-C (`.m`) / Objective-C++ (`.mm`) stub into a `.o` with
/// `clang`. Same flags as the C-stub clang path, but the language is pinned with
/// `-x objective-c[++]` (so it never relies on extension sniffing) — `cpp` selects
/// ObjC++. Frameworks (`-framework Foundation`) are link-time and
/// ride the package's `stub-cc-link-flags`, not this compile step.
fn render_build_objc_stub(
  out : String,
  cc : String,
  include_dir : String,
  stub : String,
  cc_flags : Array[String],
  cpp : Bool,
) -> @core.Command {
  let has_user_flags = !cc_flags.is_empty()
  let argv = [cc, "-o", out, "-I" + include_dir]
  argv.push("-c")
  argv.push("-fwrapv")
  argv.push("-fno-strict-aliasing")
  if !has_user_flags {
    argv.push("-O2")
  }
  // `-x <lang>` must precede the source file it applies to.
  argv.push("-x")
  argv.push(if cpp { "objective-c++" } else { "objective-c" })
  argv.push(stub)
  for f in cc_flags {
    argv.push(f)
  }
  cc_exec(argv)
}

///|
/// `ar` a package's stub `.o`s into a `.a`/`.lib`.
fn render_archive_cstubs(
  out : String,
  ar : String,
  objs : Array[String],
) -> @core.Command {
  let parts = [ar, "-r", "-c", "-s", out]
  for o in objs {
    parts.push(o)
  }
  @core.Exec(argv=parts, cwd=None)
}

///|
/// `cc`-link the emitted `.c` + runtime + stubs + toolchain libs into an exe.
fn render_make_executable(
  out : String,
  cc : String,
  include_dir : String,
  link_c : String,
  runtime_objs : Array[String],
  moonbitrun_o : String?,
  stub_libs : Array[String],
  extra_objs : Array[String],
  libs : Array[String],
  cc_flags : Array[String],
  cc_link_flags : Array[String],
  link_flags : Array[String],
) -> @core.Command {
  let has_user_flags = !cc_flags.is_empty()
  let parts = [cc, "-o", out, "-I" + include_dir]
  parts.push("-fwrapv")
  parts.push("-fno-strict-aliasing")
  if !has_user_flags {
    parts.push("-O2")
  }
  // The prebuilt runtime object goes FIRST (before the generated `.c`), matching
  // upstream `moon`; without it the macOS linker segfaults (GNU ld tolerates the
  // omission).
  match moonbitrun_o {
    Some(o) => parts.push(o)
    None => ()
  }
  parts.push(link_c)
  for o in runtime_objs {
    parts.push(o)
  }
  for l in stub_libs {
    parts.push(l)
  }
  for o in extra_objs {
    parts.push(o)
  }
  // Linux and macOS native links use libm.
  parts.push("-lm")
  for l in libs {
    parts.push(l)
  }
  for f in cc_flags {
    parts.push(f)
  }
  for f in cc_link_flags {
    parts.push(f)
  }
  // Module `link-flags`, appended to the native final link.
  for f in link_flags {
    parts.push(f)
  }
  cc_exec(parts)
}
