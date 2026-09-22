// Lowers a solved dependency graph into a concrete `@core.Action` plan that the
// existing scheduler/rebuilder can run. Mirrors moonbuild rupes-recta's
// build_plan, collapsed to the two load-bearing node kinds:
//   - BuildCore  (`moonc build-package_name`: .mbt + dep .mi  -> .core)
//   - LinkCore   (`moonc link-core`:     all .core        -> executable)
//
// Demand-driven like the original: we start from the target executable and pull
// in exactly the packages in its dependency closure.

///|
/// How to reach the standard library. When present, every `build-package_name` gets
/// `-std-path` + the prelude `-i`, and the final `link-core` is fronted with
/// `abort.core` / `core.core`. When `None`, a no-std plan is produced (handy for
/// tests and `-no-std` builds).
pub(all) struct StdConfig {
  /// The `.../lib/core/_build/<target>/release/bundle` directory.
  bundle : String
  /// The `.../lib/core` source root (for `-pkg-sources moonbitlang/core:...`).
  core_root : String
}

///|
/// The native toolchain.
pub(all) struct NativeToolchain {
  cc : String //   the C compiler (cc / gcc)
  ar : String //   the archiver
  root : String // toolchain root; every file below derives from it
  // The `zig` driver for compiling `.zig` native stubs (`zig build-obj`), if one
  // was found / configured (`MOON_ZIG` or probed off PATH). `None` when zig is
  // absent — a plan referencing a `.zig` stub then raises `ZigToolchainMissing`
  // rather than silently skipping it. C-only builds never consult this.
  zig : String?
}

///|
/// `<root>/include` — holds `moonbit.h`, passed to `cc` as `-I`.
pub fn NativeToolchain::include_dir(self : NativeToolchain) -> String {
  self.root + "/include"
}

///|
/// `<root>/lib/runtime.c` — the pre-split monolithic runtime source, and the
/// fallback for toolchains that still ship it (see [`runtime_sources`]).
pub fn NativeToolchain::runtime_c(self : NativeToolchain) -> String {
  self.root + "/lib/runtime.c"
}

///|
/// The `.c` files under `<root>/lib/runtime`, sorted so the plan is deterministic.
/// Empty when the directory is absent — i.e. on a pre-split toolchain.
fn NativeToolchain::runtime_dir_sources(
  self : NativeToolchain,
) -> Array[String] {
  let dir = self.root + "/lib/runtime"
  let names : Array[String] = []
  for entry in @os.list_dir(dir) {
    match entry {
      File(name) => if name.has_suffix(".c") { names.push(name) }
      _ => ()
    }
  }
  names.sort()
  let out : Array[String] = []
  for name in names {
    out.push(dir + "/" + name)
  }
  out
}

///|
/// True iff this toolchain ships the SPLIT runtime (`<root>/lib/runtime/*.c`).
/// Nightlies from 2026-08 replaced the single `lib/runtime.c` with that directory.
/// An in-place upgrade can leave BOTH behind (the installer overlays without
/// pruning), so the directory — the newer layout — wins.
pub fn NativeToolchain::has_split_runtime(self : NativeToolchain) -> Bool {
  !self.runtime_dir_sources().is_empty()
}

///|
/// Every runtime source to compile into the executable: the split
/// `<root>/lib/runtime/*.c` set when the toolchain has one, else the legacy single
/// `<root>/lib/runtime.c`. Upstream `moon` compiles the same set (and archives the
/// objects into `libruntime.a`; we link them directly, which needs no archiver).
pub fn NativeToolchain::runtime_sources(
  self : NativeToolchain,
) -> Array[String] {
  let split = self.runtime_dir_sources()
  if split.is_empty() {
    [self.runtime_c()]
  } else {
    split
  }
}

///|
/// `<root>/lib/{moonbit_simdutf,simdutf}.o` — prebuilt objects linked into the exe,
/// iff the toolchain `can_use_simdutf` (gcc-style on a non-Windows host). Gated on
/// the SAME `@cc` predicate as the `-DMOONBIT_USE_SIMDUTF` define so the object set
/// and the define never disagree.
///
/// Empty on a split runtime: its `runtime/utf.c` CARRIES the simdutf glue, so the
/// prebuilt objects would duplicate those symbols — and upstream stopped shipping
/// them from the same nightly that split the runtime.
pub fn NativeToolchain::extra_objs(self : NativeToolchain) -> Array[String] {
  if self.has_split_runtime() {
    []
  } else if @cc.can_use_simdutf(self.cc) {
    [self.root + "/lib/moonbit_simdutf.o", self.root + "/lib/simdutf.o"]
  } else {
    []
  }
}

///|
/// `<root>/lib/libbacktrace.a` — linked into the exe iff the toolchain
/// `can_use_stacktrace`. Gated on the SAME `@cc` predicate as the
/// `-DMOONBIT_ALLOW_STACKTRACE` define.
pub fn NativeToolchain::libs(self : NativeToolchain) -> Array[String] {
  if @cc.can_use_stacktrace(self.cc) {
    [self.root + "/lib/libbacktrace.a"]
  } else {
    []
  }
}

///|
/// `<root>/lib/libmoonbitrun.o` — the prebuilt MoonBit runtime object, linked into
/// every native executable (FIRST, before the generated `.c`), exactly as upstream
/// `moon` does (`is_libmoonbitrun_o_available`). `None` for msvc (not distributed on
/// Windows). Omitting it links on GNU ld but makes the macOS system linker SEGFAULT,
/// so it is required for a working macOS build.
pub fn NativeToolchain::moonbitrun_o(self : NativeToolchain) -> String? {
  // Also `None` for a Windows *target* (cross build): the prebuilt object is the
  // host's and is not distributed for Windows anyway — the from-source `runtime.c`
  // (compiled with the cross cc) is the whole runtime there, exactly as a native
  // Windows (msvc) build.
  if @cc.is_msvc(self.cc) || @cc.target_of(self.cc) is Windows {
    None
  } else {
    Some(self.root + "/lib/libmoonbitrun.o")
  }
}

///|
pub(all) enum Backend {
  WasmGc
  Js
  Wasm
  Native(NativeToolchain?)
  // The LLVM backend shares the entire native C toolchain pipeline (runtime,
  // C-stub archives, cc final link) — the ONLY difference is moonc's linked-core
  // artifact is a ready-to-link object (`.o`) instead of generated `.c`, and it
  // gets `-target llvm`. Mirrors rust moon, where `TargetBackend::LLVM` is
  // `is_native()` and lowers through the same path as the C backend.
  Llvm(NativeToolchain?)
}

///|
pub fn Backend::name(self : Backend) -> String {
  match self {
    WasmGc => "wasm-gc"
    Js => "js"
    Wasm => "wasm"
    Native(_) => "native"
    Llvm(_) => "llvm"
  }
}

///|
/// The native C toolchain config, present only for a native `build`. Gates the
/// runtime / C-stub / make-executable steps.
pub fn Backend::native_config(self : Backend) -> NativeToolchain? {
  match self {
    Native(nc) => nc
    Llvm(nc) => nc
    _ => None
  }
}

///|
/// Parse a `--target` string into a backend (native with NO C config — a `build`
/// replaces it with `Native(Some(nc))`). Unknown → `wasm-gc`.
pub fn Backend::parse(s : String) -> Backend {
  match s {
    "native" => Native(None)
    "llvm" => Llvm(None)
    "js" => Js
    "wasm" => Wasm
    _ => WasmGc
  }
}

///|
/// Build mode.
pub(all) enum Mode {
  Debug
  Release
}

///|
pub fn Mode::name(self : Mode) -> String {
  match self {
    Debug => "debug"
    Release => "release"
  }
}

///|
/// Knobs that shape the produced commands but are not part of the source tree.
pub(all) struct BuildConfig {
  /// The compile backend (carries the native C config when `Native`).
  backend : Backend
  /// The target platform (OS + toolchain) for a native/llvm build — the canonical
  /// source of truth for OS-dependent decisions (executable suffix, OS-conditional
  /// source gating). Ignored by wasm/js backends (which have no native OS). The cc
  /// triple in the `Native` config is derived from this same platform.
  target_platform : @os.Platform
  /// `Debug` / `Release`.
  mode : Mode
  /// Directory the `.core` / executable artifacts are written to.
  out_dir : String
  /// Compiler identity (e.g. `moonc -v`), folded into each action's digest.
  moonc_version : String
  /// Standard-library wiring, or `None` for a no-std plan.
  std : StdConfig?
  /// `--enable-coverage`: instrument compiles (and the test driver) so a test run
  /// writes `moonbit_coverage_*` traces. Off for plain build/check.
  coverage : Bool
  /// `--enable-value-tracing`: pass `-enable-value-tracing` to `moonc
  /// build-package` so traced values are reported. Off by default.
  value_tracing : Bool
  /// `moon bundle` only: `Some(<root module name>)` switches the artifact layout
  /// from the normal package-scoped build tree to the BUNDLE tree moonc's
  /// `-std-path` consumes: `<out>/<pkg-path-within-module>/<last>.{core,mi}`
  /// (e.g. `moonbitlang/core/json` → `<out>/json/json.core`). `None` everywhere
  /// else.
  bundle_of : String?
  /// Use rust moon's workspace artifact layout:
  /// `<out>/<module>/<package-path>/<last>.{core,mi}`.
  workspace_layout : Bool
  /// Rust moon's mono compatibility layout for a single local module:
  /// `<out>/<package-path>/<last>` for the root module, and
  /// `<out>/.mooncakes/<module>/<package-path>/<last>` for dependencies.
  /// When absent, the workspace layout is used.
  mono_module : String?
  /// `-d`/`--deny-warn`: treat warnings as errors (moonc `-w @a`) for the ROOT
  /// module's packages. Dependencies are suppressed regardless, so deny never
  /// applies to them.
  deny_warnings : Bool
  /// `--error-format <human|json>`: how moonc renders diagnostics. `None` = human
  /// (the default). Diagnostic-only — does NOT enter the action digest (the digest
  /// folds target/mode/moonc_version + spec identity, not this), so toggling it
  /// never forces a rebuild.
  error_format : String?
  /// `--output-wat`: emit the wasm artifact as text (`.wat`) instead of binary
  /// (`.wasm`) — moonc's `link-core -o` picks the format from the suffix. Only
  /// affects the wasm/wasm-gc backends; ignored elsewhere.
  output_wat : Bool
  /// Effective "strip debug info" decision (upstream `--strip`/`--no-strip`): when
  /// true, no `-g`/`-source-map` is emitted. `--strip` forces true, `--no-strip`
  /// forces false; with neither it defaults to `mode == Release` (so debug keeps
  /// symbols, release strips). The inverse (`debug_symbols`) reaches the executor
  /// via `BuildEnv`.
  strip : Bool
  /// Diagnostic capture/render options (upstream `--output-json` / `--no-render` /
  /// `--diagnostic-limit` / `--render-no-loc`). Diagnostic-only — never in the digest.
  diag : @core.DiagOptions
  /// `--warn-list <spec>`: a CLI moonc `-w` spec appended (after the package's own
  /// `warnings` config) for the ROOT module's packages. `None` = not given.
  cli_warn_list : String?
  /// `--sort-input`: pass source files to moonc in sorted order (deterministic),
  /// applied in `compile_sources`. Folds into the digest via the sources list.
  sort_input : Bool
  /// The experimental "new native" backend's moonc target triple (mirrors rust
  /// moon's `MOONBIT_NEW_NATIVE=1`). `Some("aarch64-apple-darwin")` /
  /// `Some("x86_64-unknown-linux-gnu")` ONLY when the host-native backend is active
  /// and opted in: then `link-core` is given `-target <triple>` and lowers straight
  /// to a ready-to-link `.o` (like the llvm backend) instead of generating `.c` for
  /// `cc` to compile. `None` everywhere else — every non-native backend, a cross
  /// build, and the default opt-out. Set at the
  /// `main`-layer config builders (it reads process env, which the pipeline doesn't).
  native_target : String?
}

///|
/// Construct a BuildConfig inside this package so callers do not need to depend
/// on cross-package record construction details.
pub fn build_config(
  backend : Backend,
  target_platform : @os.Platform,
  mode : Mode,
  out_dir : String,
  moonc_version : String,
  std : StdConfig?,
  coverage : Bool,
  value_tracing : Bool,
  bundle_of : String?,
  workspace_layout : Bool,
  mono_module : String?,
  deny_warnings : Bool,
  error_format : String?,
  output_wat : Bool,
  strip : Bool,
  diag : @core.DiagOptions,
  cli_warn_list : String?,
  sort_input : Bool,
  native_target : String?,
) -> BuildConfig {
  {
    backend,
    target_platform,
    mode,
    out_dir,
    moonc_version,
    std,
    coverage,
    value_tracing,
    bundle_of,
    workspace_layout,
    mono_module,
    deny_warnings,
    error_format,
    output_wat,
    strip,
    diag,
    cli_warn_list,
    sort_input,
    native_target,
  }
}

///|
/// The lowered plan: a map from artifact path (the scheduler's key) to the
/// action that produces it, plus the `roots` to demand. Usually one (a build's
/// executable / a lib's `.core`); `check`/`test` demand many (one `.mi` / test
/// exe per package) — there is no phony aggregate folding them into one.
pub struct Plan {
  actions : Map[String, @core.Action]
  roots : Array[String]
  /// The build-wide environment (target/mode/moonc_version), uniform across every
  /// action. Lives here once rather than on each action; the engine captures it.
  env : @core.BuildEnv
}

///|
/// Construct a plan through the build-graph invariants that all lowerers must
/// satisfy. Dependencies are artifact paths, while actions are keyed by exactly
/// one representative artifact (`primary_output`). The full `outputs` set must
/// include that representative so schedulers, caches, and exporters all see the
/// same artifact-to-producer relation.
pub fn Plan::make(
  actions : Map[String, @core.Action],
  roots : Array[String],
  env : @core.BuildEnv,
) -> Plan raise BuildPlanError {
  let producer : Map[String, String] = Map([])
  for key, act in actions {
    if key != act.primary_output {
      raise InvalidActionKey(key~, primary=act.primary_output)
    }
    if !act.outputs.contains(act.primary_output) {
      raise MissingPrimaryOutput(action=act.primary_output)
    }
    let seen : Set[String] = Set([])
    for out in act.outputs {
      if seen.contains(out) {
        raise DuplicateActionOutput(
          output=out,
          first=act.primary_output,
          second=act.primary_output,
        )
      }
      seen.add(out)
      match producer.get(out) {
        Some(first) =>
          if first != act.primary_output {
            raise DuplicateActionOutput(
              output=out,
              first~,
              second=act.primary_output,
            )
          }
        None => producer[out] = act.primary_output
      }
    }
  }
  for root in roots {
    match producer.get(root) {
      Some(_) => ()
      None => raise UnknownPlanRoot(root~)
    }
  }
  { actions, roots, env }
}

///|
pub fn Plan::actions(self : Plan) -> Map[String, @core.Action] {
  self.actions
}

///|
pub fn Plan::roots(self : Plan) -> Array[String] {
  self.roots
}

///|
pub fn Plan::env(self : Plan) -> @core.BuildEnv {
  self.env
}

///|
/// The build-wide environment derived from the config: backend / mode / compiler.
pub fn build_env(cfg : BuildConfig) -> @core.BuildEnv {
  {
    target: cfg.backend.name(),
    mode: cfg.mode.name(),
    moonc_version: cfg.moonc_version,
    error_format: cfg.error_format.unwrap_or("human"),
    debug_symbols: !cfg.strip,
    diag: cfg.diag,
  }
}

///|
/// Raised while lowering the build plan.
pub suberror BuildPlanError {
  /// The requested target package_name name matches no discovered package_name.
  PackageNotFound(fqn~ : String)
  /// A virtual package reached at link time has neither a default implementation
  /// nor a consumer-supplied `override` — there is no `.core` to link in its place.
  NoImplementation(virtual_pkg~ : String)
  /// A package in the build closure does not support the active backend (its
  /// `supported-targets` excludes it) — the build cannot proceed for this target.
  UnsupportedTarget(package_name~ : String, target~ : String)
  /// A package declares a `.zig` native stub but no `zig` driver was found
  /// (neither `MOON_ZIG` nor a `zig` on PATH) — the stub cannot be compiled.
  ZigToolchainMissing(package_name~ : String, stub~ : String)
  /// A package declares an Objective-C (`.m`/`.mm`) native stub but the active C
  /// compiler is not `clang` — only clang compiles Objective-C, so the stub
  /// cannot be built with this toolchain (`cc` carries the offending driver).
  ObjcRequiresClang(package_name~ : String, stub~ : String, cc~ : String)
  /// Internal build-plan invariant: the action map key must be the action's
  /// representative output. Without this, targets and artifact producer maps can
  /// disagree about which runnable action owns a path.
  InvalidActionKey(key~ : String, primary~ : String)
  /// Internal build-plan invariant: `outputs` is the complete produced artifact
  /// set and must include `primary_output`.
  MissingPrimaryOutput(action~ : String)
  /// Internal build-plan invariant: one artifact may have only one producer
  /// action. Two producers would make scheduling/cache restoration ambiguous.
  DuplicateActionOutput(output~ : String, first~ : String, second~ : String)
  /// Internal build-plan invariant: roots must be produced artifacts, not raw
  /// source paths or stale action keys.
  UnknownPlanRoot(root~ : String)
  /// A module's `--moonbit-unstable-prebuild` script failed: the interpreter exited
  /// non-zero (missing node/python, a script error, or non-JSON output). `script` is
  /// the resolved path, `message` the captured stderr / parse error.
  PrebuildFailed(script~ : String, message~ : String)
}
