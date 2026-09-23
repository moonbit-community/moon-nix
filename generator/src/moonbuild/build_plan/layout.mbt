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
  @posix.Path::join(workspace_package_dir(cfg, fqn), artifact_name(fqn)).0
}

///|
fn workspace_package_dir(cfg : BuildConfig, fqn : String) -> String {
  let (module_name, package_path) = split_fqn(fqn)
  if package_path == "" {
    @posix.Path::join(cfg.out_dir, module_name).0
  } else {
    @posix.Path::join(@posix.Path::join(cfg.out_dir, module_name), package_path).0
  }
}

///|
fn artifact_name(fqn : String) -> String {
  let (module_name, package_path) = split_fqn(fqn)
  if package_path == "" {
    @posix.Path::basename(module_name).to_owned()
  } else {
    @posix.Path::basename(package_path).to_owned()
  }
}

///|
fn package_dir(cfg : BuildConfig, fqn : String) -> String {
  match cfg.bundle_of {
    Some(m) =>
      if fqn == m {
        cfg.out_dir
      } else if fqn.strip_prefix(m + "/").map(rest => rest.to_owned())
        is Some(rel) {
        @posix.Path::join(cfg.out_dir, rel).0
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
        cfg.out_dir + "/" + @posix.Path::basename(m).to_owned()
      } else if fqn.strip_prefix(m + "/").map(rest => rest.to_owned())
        is Some(rel) {
        @posix.Path::join(
          @posix.Path::join(cfg.out_dir, rel),
          @posix.Path::basename(rel).to_owned(),
        ).0
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
