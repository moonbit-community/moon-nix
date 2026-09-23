// C-toolchain knowledge for the native backend: which `cc`/`ar` driver this is,
// and (eventually) the flags/commands each kind needs. moonbuild-scoped on
// purpose — only the native build path uses it (`moonbuild/action_renderer` renders the C
// commands, `build_plan` computes the `.o`/`.a`/exe paths), so it does
// NOT belong in the global `util/`.
//
// This is the SEED of what upstream moon models in `compiler_flags.rs`: a `CC`
// type carrying `CCKind` (Msvc/SystemCC/Gcc/Clang) + `ARKind` (MsvcLib/GnuAr/LlvmAr),
// with predicates (`is_msvc`/`targets_apple_darwin`/`can_use_simdutf`/
// `should_link_libm`) and command builders. mymoon does NOT model TinyCC (dropped —
// a real system cc is required for native builds). mymoon passes a bare `cc : String`
// and classifies it by basename; the
// capability predicates below (`can_use_simdutf`/`can_use_stacktrace`/
// `should_link_libm`) are where the host-OS + driver-kind rules live, so the
// command renderer (and `NativeToolchain`) ask "can this toolchain do X" instead of
// branching on the OS themselves. `targets_apple_darwin` is NOT added yet — no
// consumer needs it (macOS currently rides the generic non-Windows path); add it
// when a macOS-specific flag actually diverges.

///|
/// Whether `cc` is the MSVC compiler driver (`cl`), as opposed to a gcc-style
/// driver (gcc/clang/cc/`zig cc`). Matched by the program basename so `clang`
/// (which contains "cl") is NOT misclassified.
pub fn is_msvc(cc : String) -> Bool {
  cc == "cl" ||
  cc == "cl.exe" ||
  cc.has_suffix("/cl") ||
  cc.has_suffix("\\cl") ||
  cc.has_suffix("/cl.exe") ||
  cc.has_suffix("\\cl.exe")
}

///|
/// Whether `ar` is the MSVC archiver (`lib`), as opposed to GNU `ar`.
pub fn is_msvc_lib(ar : String) -> Bool {
  ar == "lib" ||
  ar == "lib.exe" ||
  ar.has_suffix("/lib") ||
  ar.has_suffix("\\lib") ||
  ar.has_suffix("/lib.exe") ||
  ar.has_suffix("\\lib.exe")
}

///|
/// Whether `cc`'s BASENAME is clang (`clang` / `clang.exe` / a path ending in one).
/// A name-only fast-path used by [`cc_kind`]; it does NOT catch a `cc` symlinked to
/// clang (e.g. macOS's default `cc`) — that case falls through to a `--version` probe.
fn is_clang(cc : String) -> Bool {
  cc == "clang" ||
  cc == "clang.exe" ||
  cc.has_suffix("/clang") ||
  cc.has_suffix("\\clang") ||
  cc.has_suffix("/clang.exe") ||
  cc.has_suffix("\\clang.exe")
}

///|
/// The C compiler family. Beyond the name-based MSVC/clang split, this is what the
/// capability/flag rules key on once a probe is involved.
pub(all) enum CCKind {
  Msvc
  Clang
  Gcc
}

///|
/// Split a compiler command into argv tokens on ASCII whitespace, dropping empty
/// runs. A plain driver (`cc`, `/nix/store/.../bin/clang`) yields a single-element
/// vector; a multi-word driver (`zig cc`) yields its leading tokens (`["zig","cc"]`)
/// so the program and its built-in subcommand spawn correctly under the argv-first
/// (no-shell) command runner. Mirrors moon's shlex-splitting of `CC`; a compiler PATH that
/// itself contains spaces must therefore be wrapped (same caveat as moon).
pub fn cc_argv(cc : String) -> Array[String] {
  let toks : Array[String] = []
  for part in cc.split(" ") {
    // Drop empty runs from consecutive spaces; tabs in a compiler command are
    // not expected (matches moon's space-oriented splitting).
    if part.length() > 0 {
      toks.push(part.to_owned())
    }
  }
  // An all-whitespace / empty `cc` is nonsensical, but keep the original so the
  // failure surfaces as a normal "program not found" rather than an empty argv.
  if toks.length() == 0 {
    [cc]
  } else {
    toks
  }
}

///|
/// Per-process memo of `cc string -> CCKind`, so the `--version` probe runs at most
/// once per distinct compiler per build (it is consulted from several flag sites).
let cc_kind_cache : Map[String, CCKind] = Map([])

///|
/// Resolve `cc` to its [`CCKind`]. Basename fast-path first (`cl` → Msvc, `clang` →
/// Clang — no subprocess); otherwise PROBE `<cc> --version` and sniff the banner —
/// this is how a generic `cc` that is really Apple clang (macOS) or gcc gets
/// classified, mirroring moon's own detection. A failed/empty probe defaults to Gcc
/// (the gcc-style CLI mymoon already assumes). Memoized.
pub fn cc_kind(cc : String) -> CCKind {
  match cc_kind_cache.get(cc) {
    Some(k) => return k
    None => ()
  }
  let kind = if is_msvc(cc) {
    Msvc
  } else if is_clang(cc) {
    Clang
  } else {
    let (code, banner) = @os.capture_argv([..cc_argv(cc), "--version"])
    if code == 0 {
      classify_cc_banner(banner)
    } else {
      // an unprobeable `cc` → assume the gcc-style flag set mymoon already uses.
      Gcc
    }
  }
  cc_kind_cache[cc] = kind
  kind
}

///|
/// Classify a `<cc> --version` banner. clang's banner — including Apple clang
/// (`Apple clang version …`) — contains "clang"; everything else (gcc, an
/// unrecognized driver) is treated as the gcc-style CLI. PURE, so it is unit-tested
/// against the real banners with no subprocess (see cc_wbtest).
pub fn classify_cc_banner(banner : String) -> CCKind {
  if banner.split_once("clang") is Some(_) {
    Clang
  } else {
    Gcc
  }
}

///|
/// Whether `cc` is the `zig cc` (or `zig c++`) driver — a multi-word command whose
/// first token's basename is `zig`. `zig cc` IS clang under the hood (so it
/// classifies as [`Clang`] and reuses clang's flag set), but it links with `lld`,
/// which — unlike gcc's driver — does NOT implicitly pull in the unwind library
/// that moonbit's stacktrace runtime references (`_Unwind_Backtrace` etc.). This
/// predicate lets the final-link site add `-lunwind` (zig bundles libunwind) so a
/// `MOON_CC="zig cc"` native build links out of the box.
pub fn is_zig_cc(cc : String) -> Bool {
  let toks = cc_argv(cc)
  if toks.length() < 2 {
    return false
  }
  let prog = toks[0]
  let base_is_zig = prog == "zig" ||
    prog.has_suffix("/zig") ||
    prog.has_suffix("\\zig")
  base_is_zig && (toks[1] == "cc" || toks[1] == "c++")
}

///|
/// Driver-specific warning-suppression flags for moonbit's GENERATED C. clang warns
/// on the generated code's unused values, so moon passes `-Wno-unused-value` for
/// clang (gcc doesn't need it). Empty for other drivers. Uses [`cc_kind`] (probing),
/// so a generic `cc` that is really clang (macOS) gets it too. Spliced into every
/// gcc-style C command right after `-fno-strict-aliasing`, matching moon's order.
pub fn extra_c_warning_flags(cc : String) -> Array[String] {
  if cc_kind(cc) is Clang {
    ["-Wno-unused-value"]
  } else {
    []
  }
}

///|
/// `zig cc` enables UBSan in debug builds, while upstream Rust moon's native C
/// path does not. MoonBit/core currently assumes unaligned byte-buffer u32
/// accesses are valid on supported hardware; with UBSan enabled, generated C can
/// abort on those otherwise-tolerated accesses. Disable UBSan for `zig cc` only
/// so native builds match moon's behavior.
pub fn zig_sanitizer_flags(cc : String) -> Array[String] {
  if is_zig_cc(cc) {
    ["-fno-sanitize=undefined", "-fno-sanitize=alignment"]
  } else {
    []
  }
}

///|
/// Whether the final link must pass `-lm` to pull in libm. gcc-style drivers do;
/// MSVC's CRT already provides the math functions, so it must NOT. The rule lives
/// here, not at the command renderer's branch position.
pub fn should_link_libm(cc : String) -> Bool {
  match cc_kind(cc) {
    // A Windows *target* has math in the CRT and ships no standalone `libm`, even
    // when the driver is clang (e.g. `zig cc -target x86_64-windows-msvc`).
    Clang | Gcc => !(target_of(cc) is Windows)
    Msvc => false // MSVC: CRT has the math functions
  }
}

///|
/// Whether moonbit's runtime SIMD-UTF path is usable with this toolchain — gates
/// BOTH the `-DMOONBIT_USE_SIMDUTF` define on `runtime.c` AND the `simdutf.o`
/// objects linked into the exe. The simdutf (and stacktrace) code in `runtime.c`
/// doesn't build cleanly for a Windows target (the `_WIN32`/`_MSC_VER` guards) and
/// MSVC never enables it, so it reduces to "a gcc-style driver on a non-Windows
/// host" — but expressing it as a capability keeps the OS check out of the command renderer.
pub fn can_use_simdutf(cc : String) -> Bool {
  match cc_kind(cc) {
    Clang | Gcc => if target_of(cc) is Windows { false } else { true }
    Msvc => false // MSVC never enables simdutf
  }
}

///|
/// The OS this `cc` *targets*, parsed from a `-target <triple>` flag in the cc
/// command (e.g. `zig cc -target x86_64-windows-msvc` → `Windows`), else the host
/// OS. This is the single source of truth for cross-build OS decisions: the
/// `-target` rides in the cc string into every C compile + link, so any site that
/// already holds the cc can recover the target without extra threading. A native
/// (non-cross) build has no `-target`, so this is just the host OS — unchanged.
pub fn target_of(cc : String) -> @os.OsKind {
  let argv = cc_argv(cc)
  for i in 0..<argv.length() {
    if argv[i] == "-target" && i + 1 < argv.length() {
      let triple = argv[i + 1]
      if triple.split_once("windows") is Some(_) {
        return @os.Windows
      } else if triple.split_once("macos") is Some(_) ||
        triple.split_once("darwin") is Some(_) {
        return @os.Macos
      } else if triple.split_once("linux") is Some(_) {
        return @os.Linux
      }
    }
  }
  @os.os_kind()
}

///|
/// The RAW `-target <triple>` string carried by `cc` (e.g. `x86_64-windows-msvc`),
/// or `None` for a build with no explicit `-target`. Unlike [`target_of`], which
/// collapses the triple to an `OsKind` and so DROPS the ABI (`-msvc` vs `-gnu`),
/// this preserves it verbatim — a `.zig` stub must `build-obj` for the EXACT triple
/// the cc links with, or the objects mismatch (e.g. a Windows host that explicitly
/// builds `x86_64-windows-msvc` needs the stub on msvc too, even though the OS
/// equals the host, where an `OsKind`-only check would wrongly pass `None`).
pub fn target_triple_of(cc : String) -> String? {
  let argv = cc_argv(cc)
  for i in 0..<argv.length() {
    if argv[i] == "-target" && i + 1 < argv.length() {
      return Some(argv[i + 1])
    }
  }
  None
}

///|
/// Whether moonbit's runtime stacktrace path is usable — gates BOTH the
/// `-DMOONBIT_ALLOW_STACKTRACE` define AND linking `libbacktrace.a`. Same condition
/// as [`can_use_simdutf`] today; kept a SEPARATE predicate so the two can diverge
/// per-platform later without touching the command renderer.
pub fn can_use_stacktrace(cc : String) -> Bool {
  match cc_kind(cc) {
    Clang | Gcc => if target_of(cc) is Windows { false } else { true }
    Msvc => false
  }
}
