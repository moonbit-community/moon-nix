// Toolchain configuration and validated artifact plans.

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
  cc : String // Nix supplies the C compiler as `cc`
  ar : String //   the archiver
  root : String // toolchain root; every file below derives from it
  // The `zig` driver for compiling `.zig` native stubs (`zig build-obj`), if one
  // is configured. `None` when Zig is unavailable — a plan referencing a
  // `.zig` stub then raises `ZigToolchainMissing`
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
/// when using the pre-split runtime. The generated C receives the matching
/// `-DMOONBIT_USE_SIMDUTF` define.
///
/// Empty on a split runtime: its `runtime/utf.c` CARRIES the simdutf glue, so the
/// prebuilt objects would duplicate those symbols — and upstream stopped shipping
/// them from the same nightly that split the runtime.
pub fn NativeToolchain::extra_objs(self : NativeToolchain) -> Array[String] {
  if self.has_split_runtime() {
    []
  } else {
    [self.root + "/lib/moonbit_simdutf.o", self.root + "/lib/simdutf.o"]
  }
}

///|
/// Stacktrace support on Linux and macOS links the toolchain's backtrace library.
pub fn NativeToolchain::libs(self : NativeToolchain) -> Array[String] {
  [self.root + "/lib/libbacktrace.a"]
}

///|
/// The prebuilt MoonBit runtime object, linked before generated C. macOS's
/// linker requires this ordering.
pub fn NativeToolchain::moonbitrun_o(self : NativeToolchain) -> String? {
  Some(self.root + "/lib/libmoonbitrun.o")
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
  backend : Backend
  mode : Mode
  /// Debug symbols are independent of the optimization profile.
  strip : Bool
  target_platform : @os.Platform
  out_dir : String
  /// A module bundle uses paths relative to this module; ordinary builds include the module name.
  bundle_of : String?
  std : StdConfig?
}

///|
/// Actions keyed by their primary artifact, plus the requested output artifacts.
pub struct Plan {
  actions : Map[String, @core.Action]
  roots : Array[String]
  /// Command settings shared by every action.
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
  { actions, roots, env, }
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
pub fn build_env(cfg : BuildConfig) -> @core.BuildEnv {
  {
    target: cfg.backend.name(),
    mode: cfg.mode.name(),
    debug_symbols: !cfg.strip,
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
