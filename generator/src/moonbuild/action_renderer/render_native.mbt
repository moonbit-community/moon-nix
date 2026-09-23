// Native C-toolchain command rendering: the BuildRuntime / BuildCStub /
// BuildZigStub / ArchiveCStubs / MakeExecutable arms of `render_command`, split
// out of render.mbt because they carry ALL the OS + compiler-kind branching
// (MSVC `cl` / gcc-style). `render_command` just dispatches to these.
// Mirrors the build_plan `actions.mbt` / `actions_native.mbt` split.

///|
/// Build a cc/zig `Exec` whose `argv[0]` may be a MULTI-WORD driver (`zig cc`,
/// `zig build-obj`). Every render below assembles `argv` with the bare driver
/// string at index 0; this expands that head into real argv tokens
/// (`["zig","cc", …]`) so the command runner invokes the program + its built-in
/// subcommand correctly. A plain single-word driver passes through unchanged.
fn cc_exec(argv : Array[String]) -> @core.Command {
  let head = @cc.cc_argv(argv[0])
  if head.length() <= 1 {
    return @core.Exec(argv~, cwd=None)
  }
  let out : Array[String] = [..head]
  for i in 1..<argv.length() {
    out.push(argv[i])
  }
  @core.Exec(argv=out, cwd=None)
}

///|
/// Like [`cc_exec`] but redirects the child's stdout to `stdout_path` (`ExecTo`).
/// For `zig translate-c`, whose translated Zig source goes to stdout. Same
/// multi-word-driver head expansion as `cc_exec`.
fn cc_exec_to(argv : Array[String], stdout_path : String) -> @core.Command {
  let head = @cc.cc_argv(argv[0])
  let out : Array[String] = [..head]
  for i in 1..<argv.length() {
    out.push(argv[i])
  }
  @core.ExecTo(argv=out, stdout=stdout_path)
}

///|
/// `cc`-compile one toolchain runtime source into a `.{o,obj}`.
fn render_build_runtime(
  out : String,
  cc : String,
  include_dir : String,
  runtime_c : String,
  simdutf : Bool,
  debug_info : Bool,
) -> @core.Command {
  if @cc.is_msvc(cc) {
    // Runtime follows rust moon: keep `/O2` even in debug, but emit `/Z7` when
    // debug symbols are requested.
    let argv = [cc, "/Fo" + out, "/I" + include_dir]
    if debug_info {
      argv.push("/Z7")
    }
    argv.push("/nologo")
    argv.push("/c")
    argv.push("/utf-8")
    argv.push("/wd4819")
    argv.push("/O2")
    argv.push(runtime_c)
    cc_exec(argv)
  } else {
    let argv = [cc, "-o", out, "-I" + include_dir]
    if debug_info {
      argv.push("-g")
    }
    argv.push("-c")
    argv.push("-fwrapv")
    argv.push("-fno-strict-aliasing")
    // Driver-specific warnings (clang: -Wno-unused-value) go right after
    // -fno-strict-aliasing, matching moon's flag order.
    for f in @cc.extra_c_warning_flags(cc) {
      argv.push(f)
    }
    for f in @cc.zig_sanitizer_flags(cc) {
      argv.push(f)
    }
    argv.push("-O2")
    // Stacktrace is gated by toolchain CAPABILITY, not an inline OS check (the
    // rule — "gcc-style driver on a non-Windows host" — lives in `@cc`); the
    // define pairs with `NativeToolchain`'s libbacktrace.a, which gates on the
    // SAME predicate. `simdutf` comes pre-decided from the plan, which pairs it
    // with the prebuilt simdutf objects (a split runtime compiles its own).
    if @cc.can_use_stacktrace(cc) {
      argv.push("-DMOONBIT_ALLOW_STACKTRACE")
    }
    if simdutf {
      argv.push("-DMOONBIT_USE_SIMDUTF")
    }
    // Older toolchain runtimes call rand_s without enabling its declaration in
    // stdlib.h. MinGW requires this feature macro before any runtime includes.
    if @cc.target_of(cc) is Windows {
      argv.push("-D_CRT_RAND_S")
    }
    argv.push(runtime_c)
    cc_exec(argv)
  }
}

///|
/// `cc`-compile one C stub into a `.{o,obj}` (the owning package's stub-cc flags
/// already folded into `cc_flags`).
fn render_build_cstub(
  out : String,
  cc : String,
  include_dir : String,
  stub : String,
  cc_flags : Array[String],
  debug_info : Bool,
  debug_mode : Bool,
) -> @core.Command {
  if @cc.is_msvc(cc) {
    let has_user_flags = !cc_flags.is_empty()
    let argv = [cc, "/Fo" + out, "/I" + include_dir]
    if debug_info {
      argv.push("/Z7")
    }
    argv.push("/c")
    if !has_user_flags {
      argv.push("/utf-8")
      argv.push("/wd4819")
    }
    argv.push("/nologo")
    if !has_user_flags {
      argv.push(if debug_mode { "/Od" } else { "/O2" })
    }
    argv.push(stub)
    for f in cc_flags {
      argv.push(f)
    }
    cc_exec(argv)
  } else {
    let has_user_flags = !cc_flags.is_empty()
    let argv = [cc, "-o", out, "-I" + include_dir]
    if debug_info {
      argv.push("-g")
    }
    argv.push("-c")
    argv.push("-fwrapv")
    argv.push("-fno-strict-aliasing")
    for f in @cc.extra_c_warning_flags(cc) {
      argv.push(f)
    }
    for f in @cc.zig_sanitizer_flags(cc) {
      argv.push(f)
    }
    if !has_user_flags {
      argv.push(if debug_mode { "-Og" } else { "-O2" })
    }
    argv.push(stub)
    for f in cc_flags {
      argv.push(f)
    }
    cc_exec(argv)
  }
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
  // On a Windows MSVC target, zig's codegen emits the GNU stack-probe builtin
  // `__chkstk_ms`, but zig's MSVC-ABI compiler-rt only exports it for `-gnu`
  // (it ships `__chkstk` for MSVC) — so the separately-linked stub object fails
  // with `undefined symbol: __chkstk_ms`. `-fno-stack-check` switches codegen to
  // the MSVC `__chkstk` (provided by the CRT) and, as a bonus, drops the
  // `std.debug` self-info path that pulled the unresolved `LdrRegisterDllNotification`.
  // Stubs are thin syscall wrappers (tiny stack frames), so dropping the >4KB
  // guard-page probe is safe. POSIX targets keep probing (their compiler-rt has it).
  let is_windows_target = match target {
    Some(t) => t.split_once("windows") is Some(_)
    None => false
  }
  let no_stack_check : Array[String] = if is_windows_target {
    ["-fno-stack-check"]
  } else {
    []
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
        ..no_stack_check,
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
    ..no_stack_check,
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
/// ObjC++. The caller has already gated on `cc_kind == Clang`, so there is no
/// MSVC branch here. Frameworks (`-framework Foundation`) are link-time and
/// ride the package's `stub-cc-link-flags`, not this compile step.
fn render_build_objc_stub(
  out : String,
  cc : String,
  include_dir : String,
  stub : String,
  cc_flags : Array[String],
  cpp : Bool,
  debug_info : Bool,
  debug_mode : Bool,
) -> @core.Command {
  let has_user_flags = !cc_flags.is_empty()
  let argv = [cc, "-o", out, "-I" + include_dir]
  if debug_info {
    argv.push("-g")
  }
  argv.push("-c")
  argv.push("-fwrapv")
  argv.push("-fno-strict-aliasing")
  for f in @cc.extra_c_warning_flags(cc) {
    argv.push(f)
  }
  for f in @cc.zig_sanitizer_flags(cc) {
    argv.push(f)
  }
  if !has_user_flags {
    argv.push(if debug_mode { "-Og" } else { "-O2" })
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
  // MSVC `lib /OUT:<a>`; GNU `ar -rcs <a>`.
  let parts = if @cc.is_msvc_lib(ar) {
    [ar, "/nologo", "/OUT:" + out]
  } else {
    [ar, "-r", "-c", "-s", out]
  }
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
  debug_info : Bool,
  debug_mode : Bool,
  gen_dsym : Bool,
) -> @core.Command {
  if @cc.is_msvc(cc) {
    let has_user_flags = !cc_flags.is_empty()
    let lib_dir = @pathx.parent(include_dir) + "/lib"
    let parts = [
      cc,
      "/Fe" + out,
      "/I" + include_dir,
      "/Fo" + @pathx.parent(out) + "/",
    ]
    if debug_info {
      parts.push("/Z7")
    }
    if !has_user_flags {
      parts.push("/utf-8")
      parts.push("/wd4819")
    }
    parts.push("/nologo")
    if !has_user_flags {
      parts.push(if debug_mode { "/Od" } else { "/O2" })
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
    parts.push("/link")
    parts.push("/LIBPATH:" + lib_dir)
    cc_exec(parts)
  } else {
    let has_user_flags = !cc_flags.is_empty()
    let parts = [cc, "-o", out, "-I" + include_dir]
    if debug_info {
      parts.push("-g")
    }
    parts.push("-fwrapv")
    parts.push("-fno-strict-aliasing")
    for f in @cc.extra_c_warning_flags(cc) {
      parts.push(f)
    }
    for f in @cc.zig_sanitizer_flags(cc) {
      parts.push(f)
    }
    if !has_user_flags {
      parts.push(if debug_mode { "-Og" } else { "-O2" })
    }
    // The prebuilt runtime object goes FIRST (before the generated `.c`), matching
    // upstream `moon`; without it the macOS linker segfaults (GNU ld tolerates the
    // omission). `None` for msvc.
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
    // `-lm` iff the toolchain links libm explicitly (gcc-style; MSVC has it in
    // the CRT and takes a separate branch). Rule lives in `@cc`.
    if @cc.should_link_libm(cc) {
      parts.push("-lm")
    }
    for l in libs {
      parts.push(l)
    }
    // `zig cc` links via lld, which (unlike gcc's driver) doesn't implicitly pull
    // in the unwind library moonbit's stacktrace runtime references. Add it
    // explicitly so a `MOON_CC="zig cc"` build links — only when stacktrace is on
    // (the sole consumer of `_Unwind_*`); zig bundles libunwind so it resolves.
    if @cc.is_zig_cc(cc) && @cc.can_use_stacktrace(cc) {
      parts.push("-lunwind")
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
    if gen_dsym {
      // macOS: the clang driver does not reliably auto-run `dsymutil` on a
      // combined compile+link, so emit the `<exe>.dSYM` bundle explicitly (the
      // panic runtime's libbacktrace reads it to symbolicate). Run as a shell
      // sequence. The driver head is expanded first (`zig cc` → `zig cc`, two argv
      // tokens — quoting it whole would make the shell seek a program literally
      // named "zig cc"); every token is then double-quoted so paths with spaces
      // survive. `dsymutil` is invoked by ABSOLUTE path: a `zig cc` toolchain need
      // not carry one, but `/usr/bin/dsymutil` (a shim over the active Xcode) is
      // always present on macOS.
      let toks : Array[String] = [..@cc.cc_argv(parts[0])]
      for i in 1..<parts.length() {
        toks.push(parts[i])
      }
      let sb = StringBuilder()
      for i, p in toks {
        if i != 0 {
          sb.write_string(" ")
        }
        sb.write_string("\"")
        sb.write_string(p)
        sb.write_string("\"")
      }
      sb.write_string(" && /usr/bin/dsymutil \"")
      sb.write_string(out)
      sb.write_string("\"")
      @core.Shell(command=sb.to_string(), cwd=None)
    } else {
      cc_exec(parts)
    }
  }
}
