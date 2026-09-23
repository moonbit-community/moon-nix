// Artifact path layout: where a package_name's `.core` / `.mi` / executable live.
// Pure functions of (BuildConfig, fqn) — no graph, no toolchain, no commands.
// Consumers downstream read `act.primary_output`; these stay private to the planner.

///|
/// Split an FQN into the module name and the package path. Moon module names are
/// conventionally `owner/name`; keep that two-segment prefix when available.
fn split_fqn(fqn : String) -> (String, String) {
  let first = match fqn.find("/") {
    Some(i) => i
    None => return (fqn, "")
  }
  let rest_start = first + 1
  let second = match fqn[rest_start:].find("/") {
    Some(i) => rest_start + i
    None => return (fqn, "")
  }
  let module_name = fqn[:second].to_owned()
  let pkg_start = second + 1
  if pkg_start < fqn.length() {
    (module_name, fqn[pkg_start:].to_owned())
  } else {
    (module_name, "")
  }
}

///|
fn workspace_artifact_stem(cfg : BuildConfig, fqn : String) -> String {
  @pathx.join([workspace_package_dir(cfg, fqn), artifact_name(fqn)])
}

///|
fn workspace_package_dir(cfg : BuildConfig, fqn : String) -> String {
  let (module_name, package_path) = split_fqn(fqn)
  if package_path == "" {
    @pathx.join([cfg.out_dir, module_name])
  } else {
    @pathx.join([cfg.out_dir, module_name, package_path])
  }
}

///|
fn artifact_name(fqn : String) -> String {
  let (module_name, package_path) = split_fqn(fqn)
  if package_path == "" {
    last_name_seg(module_name)
  } else {
    last_name_seg(package_path)
  }
}

///|
fn package_dir(cfg : BuildConfig, fqn : String) -> String {
  match cfg.bundle_of {
    Some(m) =>
      if fqn == m {
        cfg.out_dir
      } else if @pathx.strip_under(fqn, m) is Some(rel) {
        @pathx.join([cfg.out_dir, rel])
      } else {
        workspace_package_dir(cfg, fqn)
      }
    None => workspace_package_dir(cfg, fqn)
  }
}

///|
/// The artifact-filename suffix for a build target kind. A `SubPackage` target's
/// `.core`/`.mi` carry `_sub` so they don't collide with the package's `Primary`
/// artifacts (both compile under the SAME `-pkg` name, only the files differ).
fn kind_suffix(kind : @pkg_solve.TargetKind) -> String {
  match kind {
    SubPackage => "_sub"
    _ => ""
  }
}

///|
/// Artifact paths include the module name, except inside a module bundle.
fn artifact_stem(cfg : BuildConfig, fqn : String) -> String {
  match cfg.bundle_of {
    Some(m) =>
      if fqn == m {
        cfg.out_dir + "/" + last_name_seg(m)
      } else if @pathx.strip_under(fqn, m) is Some(rel) {
        @pathx.join([cfg.out_dir, rel, last_name_seg(rel)])
      } else {
        workspace_artifact_stem(cfg, fqn)
      }
    None => workspace_artifact_stem(cfg, fqn)
  }
}

///|
/// Artifact path for a package_name's `.core`.
fn core_path(cfg : BuildConfig, fqn : String) -> String {
  artifact_stem(cfg, fqn) + ".core"
}

///|
/// The `.mi` interface path for a package_name.
pub fn mi_path(cfg : BuildConfig, fqn : String) -> String {
  artifact_stem(cfg, fqn) + ".mi"
}

///|
/// Build-target-aware `.core` path: the `Primary` target's plain `.core`, or a
/// `SubPackage` target's `_sub.core`.
fn core_path_t(
  cfg : BuildConfig,
  fqn : String,
  kind : @pkg_solve.TargetKind,
) -> String {
  artifact_stem(cfg, fqn) + kind_suffix(kind) + ".core"
}

///|
/// Build-target-aware `.mi` path (see [`core_path_t`]).
fn mi_path_t(
  cfg : BuildConfig,
  fqn : String,
  kind : @pkg_solve.TargetKind,
) -> String {
  artifact_stem(cfg, fqn) + kind_suffix(kind) + ".mi"
}

///|
/// The `link-core` output extension per backend.

///|
fn link_ext(cfg : BuildConfig) -> String {
  match cfg.backend {
    Js => ".js"
    Native(_) => ".c"
    Llvm(_) => ".o"
    _ => ".wasm"
  }
}

///|
fn exe_path(cfg : BuildConfig, fqn : String, _bin_name : String?) -> String {
  artifact_stem(cfg, fqn) + link_ext(cfg)
}

///|
/// The final native executable. Rust moon always uses `.exe` for native/LLVM
/// executable artifacts inside `_build`, independent of the host OS. `bin-name`
/// does not rename internal build graph artifacts.
fn native_exe_path(
  cfg : BuildConfig,
  fqn : String,
  _bin_name : String?,
) -> String {
  artifact_stem(cfg, fqn) + ".exe"
}

///|
/// The basename of a FILESYSTEM path (splits on BOTH `/` and `\`; see
/// `@pathx.os_last_seg`). For LOGICAL module/package names use `last_name_seg`.
fn last_seg(s : String) -> String {
  @pathx.os_last_seg(s)
}

///|
/// The last segment of a LOGICAL name (module/package path). Using an OS-aware
/// basename here mis-splits on Windows (no `\` in `encoding/utf8` → the whole
/// string is returned), which doubled std-bundle `.mi` paths
/// (`encoding/utf8/encoding/utf8.mi`); `@pathx.last_seg` is POSIX-only.
fn last_name_seg(s : String) -> String {
  @pathx.last_seg(s)
}

///|
/// The workspace listing (`-all-pkgs`) path. EVERY compile gets `-all-pkgs` so
/// moonc can lazily load the `.mi` of packages reached only INDIRECTLY (a type
/// re-exported through an intermediate package whose own `.mi` doesn't carry the
/// type's trait `impl`s — e.g. an `#external` `Fd` with explicit `impl Eq`/`Hash`
/// behind a `pub type Fd = @types.Fd` alias). Without it `find_trait_impl` can't
/// reach the defining package and reports a spurious "does not implement trait"
/// (E4018). This matches rust moon, which passes `-all-pkgs` on every build-package.
/// The exporter records package interfaces; the Nix runner writes the listing
/// with the resolved artifact paths.
pub fn all_pkgs_path(cfg : BuildConfig) -> String {
  cfg.out_dir + "/all_pkgs.json"
}

///|
/// Whether `link-core` emits a `<out>.map` source map for this config: debug mode
/// on a wasm/js backend. The native-family backends (native C, llvm) codegen to
/// objects and reject `-source-map`, so they never produce a map. Mirrors the
/// command renderer's `-source-map` gate, so the build plan can declare the `.map` as a
/// declared byproduct.
fn emits_source_map(cfg : BuildConfig) -> Bool {
  guard cfg.mode is Debug else { return false }
  match cfg.backend {
    WasmGc | Wasm | Js => true
    Native(_) | Llvm(_) => false
  }
}
