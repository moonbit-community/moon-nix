// Compile-input resolution: interpret the discovered facts (source files,
// imports, conditional `targets`) against the selected backend in release mode. This is the
// layer `discover` deliberately deferred — it gathered facts without filtering;
// here they are filtered and resolved for a concrete compile.

///|
/// The source files that feed one package's compile/check.
fn compile_sources(
  pkg : @model.Package,
  generated : Array[String],
  cfg : BuildConfig,
) -> Array[String] {
  let sources : Array[String] = []
  let seen : Set[String] = Set([])
  for f in pkg.source_files {
    if is_test_file(f) {
      continue
    }
    if target_excludes(pkg, f, cfg) {
      continue
    }
    if !seen.contains(f) {
      seen.add(f)
      sources.push(f)
    }
  }
  for f in generated {
    if !seen.contains(f) {
      seen.add(f)
      sources.push(f)
    }
  }
  // `--sort-input`: pass the source files to moonc in a deterministic (sorted)
  // order rather than discovery order. moonc has no flag for this — it is moon's
  // job to order the input list (upstream's `--sort-input`).
  // `--sort-input`: pass the source files to moonc in a deterministic, LEXICAL
  // order (not discovery order). moonc has no flag for this — it is moon's job to
  // order the input list (upstream's `--sort-input`). NB `String`'s default
  // `Compare` is length-first, so use `lexical_compare` for true alphabetical order.
  sources.sort_by(fn(a, b) { a.lexical_compare(b) })
  sources
}

///|
/// The dependency `.mi` imports (`-i <mi>:<import_alias>`) of a build target,
/// structured. Each dependency's `.mi` path is resolved per the edge's target kind
/// — a `sub-package: true` import points at the dependency's `_sub.mi`.
fn collect_dep_imports(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  target : @pkg_solve.BuildTarget,
  cfg : BuildConfig,
) -> Array[@core.MiDep] {
  let out : Array[@core.MiDep] = []
  for entry in deps_rel.deps_of_target(target) {
    let (to, edge) = entry
    out.push({
      mi: mi_path_t(cfg, packages.get_fqn(to.pkg), to.kind),
      import_alias: edge.short_alias,
    })
  }
  out
}

///|
/// The standard-library sub-package_name imports (`moonbitlang/core/<sub>`) in an
/// import list, structured. They are PROVIDED by the bundle (their `.core` lives
/// inside the linked `core.core`); kept as (sub/last/import_alias) so each renderer
/// builds the path. Takes an explicit `imports` list so a sub-package's own (not
/// the parent's) imports can be resolved.
fn collect_std_imports(
  packages : @model.PackageTable,
  imports : Array[@config.ImportSpec],
  cfg : BuildConfig,
) -> Array[@core.StdImport] {
  let out : Array[@core.StdImport] = []
  guard cfg.std is Some(_) else { return out }
  for spec in imports {
    // A locally-discovered package wins over the bundle (the project IS
    // `moonbitlang/core`): the solver made it a project edge, so wiring the
    // bundle `.mi` too would import the same alias twice.
    if @pkg_solve.is_stdlib_import(spec.path) &&
      packages.get_package_id_by_name(spec.path) is None {
      let sub = spec.path.strip_prefix("moonbitlang/core/").unwrap().to_owned()
      let last = last_name_seg(sub)
      // Explicit import_alias if declared (e.g. `immut/sorted_map`); else the last seg.
      let import_alias = match spec.import_alias {
        Some(a) => a
        None => last
      }
      out.push({ sub, last, import_alias, })
    }
  }
  out
}

///|
fn is_test_file(name : String) -> Bool {
  name.has_suffix("_test.mbt") || name.has_suffix("_wbtest.mbt")
}

///|
/// Whether `file` is excluded from the active target. Two layers of per-file
/// conditional compilation, in precedence order:
///
///  1. An explicit `targets:` entry in `moon.pkg` is authoritative — the file
///     compiles iff its cond-expr holds for the selected backend in release mode. This is how
///     conditional sources are kept apart so they don't collide (e.g. two files
///     declaring the same type for different backends).
///  2. A recognized backend suffix in the FILENAME (`timer.js.mbt`) gates the file
///     to that backend implicitly — MoonBit's filename convention, used by upstream
///     packages (e.g. `moonbitlang/async`) without listing them in `targets:`.
///  3. An OS suffix in the FILENAME (`metal.macos.mbt`, `epoll.linux.mbt`,
///     `iocp.windows.mbt`) gates the file to that OS — for native bindings whose
///     implementation is platform-specific. The active OS is the native build's
///     target OS (cross `--target-os`, else the host); wasm/js builds have no OS,
///     so any OS-suffixed file is excluded there.
///
/// A file with none of these compiles everywhere.
fn target_excludes(
  pkg : @model.Package,
  file : String,
  cfg : BuildConfig,
) -> Bool {
  match pkg.targets.get(last_seg(file)) {
    Some(expr) =>
      return !@config.cond_eval(expr, cfg.backend.name(), "release")
    None => ()
  }
  match filename_backend(file) {
    Some(b) => if b != cfg.backend.name() { return true }
    None => ()
  }
  match filename_os(file) {
    Some(file_os) => active_os(cfg) != Some(file_os)
    None => false
  }
}

///|
/// The OS a native/llvm build targets (from the resolved `target_platform`), or
/// `None` for a wasm/js build (no native OS).
fn active_os(cfg : BuildConfig) -> @os.OsKind? {
  match cfg.backend {
    Native(_) | Llvm(_) => Some(cfg.target_platform.os)
    _ => None
  }
}

///|
/// If `file`'s basename carries an OS suffix before `.mbt` (`worker.linux.mbt` →
/// `Linux`), return that OS; such a file compiles ONLY for that OS. `None` for an
/// ordinary name or a non-OS final stem (backend suffixes parse to `None` here —
/// they are a disjoint set handled by [`filename_backend`]).
fn filename_os(file : String) -> @os.OsKind? {
  let base = last_seg(file)
  guard base.rev_split_once(".") is Some((stem, "mbt")) else { return None }
  guard stem.rev_split_once(".") is Some((_, tok)) else { return None }
  @os.OsKind::parse(tok.to_owned())
}

///|
/// The recognized backend names that may appear as a filename suffix before
/// `.mbt` (`foo.js.mbt`, `foo.wasm-gc.mbt`). These match `Backend::name()`.
let backend_suffixes : Array[String] = [
  "wasm-gc", "wasm", "js", "native", "llvm",
]

///|
/// If `file`'s basename carries a recognized backend suffix before `.mbt`
/// (e.g. `timer.js.mbt` → `"js"`), return that backend name; such a file compiles
/// ONLY for that backend. Returns `None` for an ordinary `.mbt` name, or a dotted
/// name whose final stem segment isn't a recognized backend (`my.config.mbt`).
fn filename_backend(file : String) -> String? {
  let base = last_seg(file)
  guard base.rev_split_once(".") is Some((stem, "mbt")) else { return None }
  guard stem.rev_split_once(".") is Some((_, tok)) else { return None }
  let tok = tok.to_owned()
  if backend_suffixes.contains(tok) {
    Some(tok)
  } else {
    None
  }
}
