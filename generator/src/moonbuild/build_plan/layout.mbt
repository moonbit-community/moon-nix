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
fn mono_artifact_stem(
  cfg : BuildConfig,
  main_module : String,
  fqn : String,
) -> String {
  @pathx.join([mono_package_dir(cfg, main_module, fqn), artifact_name(fqn)])
}

///|
fn mono_package_dir(
  cfg : BuildConfig,
  main_module : String,
  fqn : String,
) -> String {
  if fqn == main_module {
    return cfg.out_dir
  }
  if @pathx.strip_under(fqn, main_module) is Some(package_path) {
    if package_path == "" {
      cfg.out_dir
    } else {
      @pathx.join([cfg.out_dir, package_path])
    }
  } else {
    let (module_name, package_path) = split_fqn(fqn)
    let parts : Array[String] = [cfg.out_dir]
    parts.push(".mooncakes")
    parts.push(module_name)
    if package_path != "" {
      parts.push(package_path)
    }
    @pathx.join(parts)
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
    None =>
      if cfg.mono_module is Some(m) {
        mono_package_dir(cfg, m, fqn)
      } else {
        workspace_package_dir(cfg, fqn)
      }
  }
}

///|
/// The artifact-filename suffix for a build target kind. A `SubPackage` target's
/// `.core`/`.mi` carry `_sub` so they don't collide with the package's `Primary`
/// artifacts (both compile under the SAME `-pkg` name, only the files differ).
fn kind_suffix(kind : @pkg_solve.TargetKind) -> String {
  match kind {
    WhiteboxTest => ".whitebox_test"
    BlackboxTest => ".blackbox_test"
    InlineTest => ".internal_test"
    SubPackage => "_sub"
    _ => ""
  }
}

///|
/// The artifact path stem for a package_name (no extension). Normal builds use
/// Rust moon's package-scoped mono layout:
/// `<out>/<pkg-path>/<artifact>` for the root module and
/// `<out>/.mooncakes/<module>/<pkg-path>/<artifact>` for dependencies. Workspace
/// layout keeps the module name for every package. `moon bundle` keeps the bundle
/// tree moonc's `-std-path` consumes.
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
    None =>
      if cfg.mono_module is Some(m) {
        mono_artifact_stem(cfg, m, fqn)
      } else {
        workspace_artifact_stem(cfg, fqn)
      }
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
/// Whether `link-core` emits a `<out>.map` source map for this config: debug mode
/// on a wasm/js backend. The native-family backends (native C, llvm) codegen to
/// objects and reject `-source-map`, so they never produce a map. Mirrors the
/// executor's `-source-map` gate, so the build plan can declare the `.map` as a
/// cached byproduct and a cache HIT restores it.
fn emits_source_map(cfg : BuildConfig) -> Bool {
  guard cfg.mode is Debug else { return false }
  // `--output-wat` swaps the artifact to textual `.wat`; don't assume a `.wat.map`
  // is produced (keep the pre-existing "not cached" behavior for that niche path).
  guard !cfg.output_wat else { return false }
  match cfg.backend {
    WasmGc | Wasm | Js => true
    Native(_) | Llvm(_) => false
  }
}

///|
fn link_ext(cfg : BuildConfig) -> String {
  match cfg.backend {
    Js => ".js"
    // Native: normally moonc emits generated `.c` for cc to compile. Under the
    // "new native" backend (`cfg.native_target` set) moonc lowers straight to a
    // ready-to-link object — exactly like llvm — so cc links it directly.
    Native(nc) =>
      if cfg.native_target is Some(_) {
        match nc {
          Some(nc) => obj_ext(nc)
          None => ".o"
        }
      } else {
        ".c"
      }
    // moonc emits a ready-to-link native object for `-target llvm` (rust moon's
    // `OutputFormat::LLVM => O_EXT`), so cc links it directly — no compile step.
    Llvm(Some(nc)) => obj_ext(nc)
    Llvm(None) => ".o"
    // wasm / wasm-gc: `--output-wat` switches the artifact to textual `.wat`.
    _ => if cfg.output_wat { ".wat" } else { ".wasm" }
  }
}

///|
/// The `link-core` output: `<package-dir>/<artifact>.{js,wasm,c,o}` per backend.
/// Rust moon parks the "new native" object output under `__moonbit_link_core__`
/// so it never collides with other package-local object files.
fn exe_path(cfg : BuildConfig, fqn : String, _bin_name : String?) -> String {
  match cfg.backend {
    Native(_) if cfg.native_target is Some(_) =>
      @pathx.join([
        package_dir(cfg, fqn),
        "__moonbit_link_core__",
        artifact_name(fqn),
      ]) +
      link_ext(cfg)
    _ => artifact_stem(cfg, fqn) + link_ext(cfg)
  }
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
/// The listing itself is written by the executor (`LocalBackend.realize`) from the
/// plan's compile actions — see `provision_workspace_listing`.
pub fn all_pkgs_path(cfg : BuildConfig) -> String {
  cfg.out_dir + "/all_pkgs.json"
}
