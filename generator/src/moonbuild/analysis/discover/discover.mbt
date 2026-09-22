// Discovers packages from a source-directory layout.
// Dependency resolution across modules
// is a later stage; this one only touches the filesystem.

///|
/// Directories the walk never descends into. NIt is purely PERFORMANCE: each is
/// a LARGE, package-free tree (build output, VCS object store, node deps, the fetched
/// dependency cache) that discovery would otherwise stat on every build/check. Only
/// big trees earn a slot.
let ignore_dirs : Array[String] = [
  "_build", ".git", "node_modules", ".mooncakes",
]

///|
/// Discover every package_name in the local module rooted at `dir`.
pub fn discover_local_module(
  dir : String,
  scanner? : &SourceScanner = PlainScanner::{  },
) -> @model.DiscoverResult raise @model.DiscoverError {
  let res = @model.DiscoverResult::new()
  let (ctx, scan_root) = register_module(res, dir, scanner)
  walk(res, ctx, scan_root, [])
  res
}

///|
/// Discover packages across a whole resolved closure: `dirs` is the module-root
/// directories (the local root first, then each fetched dependency module). Each
/// dir holds a `moon.mod`. This is what feeds a build that depends on external
///  modules — the output of the resolver becomes the input here.
pub fn discover_modules(
  dirs : Array[String],
  scanner? : &SourceScanner = PlainScanner::{  },
) -> @model.DiscoverResult raise @model.DiscoverError {
  let res = @model.DiscoverResult::new()
  // Register every module first (manifest read only — assigns the module id, builds
  // its ctx; NO tree walk), so module ids stay deterministic in `dirs` order.
  let mods : Array[(ModuleCtx, String)] = []
  for dir in dirs {
    mods.push(register_module(res, dir, scanner))
  }
  guard mods.length() > 0 else { return res }
  // The ROOT module (dirs[0]) is walked in full: `moon check`/`build`/`test` operate
  // on ALL of its packages, so every one must be discovered.
  let (root_ctx, root_scan) = mods[0]
  walk(res, root_ctx, root_scan, [])
  // DEPENDENCY modules are discovered LAZILY: only the packages actually reachable
  // from the root's import graph are walked, never a dep module's whole tree (e.g.
  // all of `moonbitlang/x` when one package is used). Pruning the unused dep
  // packages is the bulk of discovery's cost (each is a dir list + per-file stat).
  demand_discover_deps(res, mods, scanner)
  res
}

///|
/// Every package_name this package can pull into the build graph: its imports
/// (regular + test-only) plus the virtual packages it implements / overrides. Used
/// to drive demand discovery — following these from the root reaches exactly the
/// set the solver/planner can ever need (a superset of what any one command builds).
fn package_edges(pkg : @model.DiscoveredPackage) -> Array[String] {
  let out : Array[String] = []
  for s in pkg.imports {
    out.push(s.path)
  }
  for s in pkg.wbtest_imports {
    out.push(s.path)
  }
  for s in pkg.test_imports {
    out.push(s.path)
  }
  match pkg.implement {
    Some(p) => out.push(p)
    None => ()
  }
  for p in pkg.overrides {
    out.push(p)
  }
  out
}

///|
/// Locate the dependency module that owns the package_name `fqn`, returning its
/// ctx, scan root, and the module-relative path segments — exactly the inverse of
/// how `walk` derives an FQN from a directory (`module_name` + segments under the
/// scan root). Longest module-name prefix wins (so `a/b/c` resolves to module `a/b`
/// over `a`). `None` = not a known dependency package (e.g. a stdlib import, or the
/// root module's own packages) — such edges are simply not discovered here.
fn locate_dep_package(
  by_name : Map[String, (ModuleCtx, String)],
  fqn : String,
) -> (ModuleCtx, String, Array[String])? {
  let mut best : (ModuleCtx, String, Array[String])? = None
  let mut best_len = -1
  for name, v in by_name {
    let (ctx, scan) = v
    let rel : Array[String]? = if fqn == name {
      Some([])
    } else {
      match @pathx.strip_under(fqn, name) {
        Some(rest) =>
          Some(rest.split("/").map(seg => seg.to_owned()).to_array())
        None => None
      }
    }
    match rel {
      Some(segs) =>
        if name.length() > best_len {
          best = Some((ctx, scan, segs))
          best_len = name.length()
        }
      None => ()
    }
  }
  best
}

///|
/// Discover dependency-module packages on demand: BFS over the import/implement/
/// override graph starting from the already-discovered (root) packages, walking
/// each reachable dep package exactly once and never touching unused ones.
fn demand_discover_deps(
  res : @model.DiscoverResult,
  mods : Array[(ModuleCtx, String)],
  _scanner : &SourceScanner,
) -> Unit raise @model.DiscoverError {
  // Dependency modules only (skip the root at index 0): name -> (ctx, scan root).
  let by_name : Map[String, (ModuleCtx, String)] = Map([])
  for i in 1..<mods.length() {
    let (ctx, scan) = mods[i]
    by_name[ctx.name] = (ctx, scan)
  }
  // `seen` covers every already-discovered package (the root's) so we neither
  // re-discover them nor chase intra-root edges.
  let seen : Set[String] = Set([])
  let queue : Array[String] = []
  for pkg in res.all_packages() {
    seen.add(pkg.fqn.to_string())
  }
  for pkg in res.all_packages() {
    for e in package_edges(pkg) {
      queue.push(e)
    }
  }
  let mut qi = 0
  while qi < queue.length() {
    let fqn = queue[qi]
    qi += 1
    if seen.contains(fqn) {
      continue
    }
    seen.add(fqn)
    // Not a known dependency package (stdlib / root-module edge) — skip; the solver
    // resolves stdlib via the bundle, and root packages are already discovered.
    guard locate_dep_package(by_name, fqn) is Some((ctx, scan, rel)) else {
      continue
    }
    let dir = if rel.is_empty() { scan } else { scan + "/" + rel.join("/") }
    // A path with no manifest isn't a real package — leave it for the solver to
    // report as an unresolved import, matching the old full-walk behavior.
    if !@parse.has_pkg(dir) {
      continue
    }
    let pkg = discover_one_package(ctx, dir, rel)
    res.add_package(ctx.mid, pkg) |> ignore
    for e in package_edges(pkg) {
      queue.push(e)
    }
  }
}

///|
/// The immutable per-module context threaded through the package walk: everything
/// that stays constant for one `moon.mod`'s subtree — its id, name, root, the
/// module-level flags/rules/diagnostics, and the source scanner. Only the current
/// directory (`abs`) and its module-relative segments (`rel`) change as `walk`
/// recurses, so bundling the rest here keeps the recursion a 4-argument call
/// instead of re-threading a dozen scalars at every level.
priv struct ModuleCtx {
  mid : @model.ModuleId
  name : String
  root : String
  compile_flags : Array[String]
  link_flags : Array[String]
  supported : Array[String]?
  rules : Array[@config.ModRule]
  warn : String?
  alert : String?
  // `--moonbit-unstable-prebuild` resolved to an ABSOLUTE script path (None if unset).
  prebuild_script : String?
  scanner : &SourceScanner
}

///|
/// Read the module at `dir`, register it, and walk its source tree. Honors
/// `options(source: "src")` — the walk starts at `dir/<source>` and package_name
/// paths are relative to that (so `DzmingLi/pwz` resolves to `DzmingLi/pwz/pwz`,
/// not `…/src/pwz`). The walk treats any directory with a `moon.pkg` as a
/// package_name, skipping ignored dirs and never crossing into a nested module.
/// Read a module's manifest, register it (assigning its module id), and build its
/// `ModuleCtx` — WITHOUT walking its tree. Returns the ctx and its scan root (the
/// module dir, or `dir/<source>` when `options(source:)` is set). Walking is the
/// caller's choice: the root module is walked in full, dep modules on demand.
fn register_module(
  res : @model.DiscoverResult,
  dir : String,
  scanner : &SourceScanner,
) -> (ModuleCtx, String) raise @model.DiscoverError {
  // Module manifest: DSL `moon.mod`, else JSON `moon.mod.json`.
  let entries = match @parse.load_mod(dir) {
    Some(e) => e
    None => raise @model.CantReadModuleFile(path=dir + "/moon.mod")
  }
  let m = @config.decode_mod(entries) catch {
    e => raise @model.DecodeModule(path=dir + "/moon.mod", inner=e)
  }
  let ctx = ModuleCtx::{
    mid: res.add_module(m.name),
    name: m.name,
    root: dir,
    compile_flags: m.compile_flags,
    link_flags: m.link_flags,
    supported: m.supported_targets,
    rules: m.rules,
    warn: m.warn_list,
    alert: m.alert_list,
    // Resolve the prebuild script (manifest path is relative to the module root).
    prebuild_script: m.unstable_prebuild.map(s => dir + "/" + s),
    scanner,
  }
  let scan_root = if m.source == "" { dir } else { dir + "/" + m.source }
  (ctx, scan_root)
}

///|
/// Recursively walk `abs` (relative segments `rel`), registering packages into
/// `res`. A directory may be both a package_name and contain sub-packages, so we
/// recurse regardless of whether the current directory is itself a package_name.
fn walk(
  res : @model.DiscoverResult,
  ctx : ModuleCtx,
  abs : String,
  rel : Array[String],
) -> Unit raise @model.DiscoverError {
  let has_pkg = @parse.has_pkg(abs)
  if has_pkg {
    let pkg = discover_one_package(ctx, abs, rel)
    res.add_package(ctx.mid, pkg) |> ignore
  }

  // Collect sub-directory names and sort for deterministic discovery order.
  let dirs : Array[String] = []
  for entry in @os.list_dir(abs) {
    match entry {
      Dir(name) => dirs.push(name)
      _ => ()
    }
  }
  dirs.sort()
  for name in dirs {
    if ignore_dirs.contains(name) {
      continue
    }
    let child = abs + "/" + name
    // Don't descend into a nested module — it owns its own package_name namespace.
    // Which OTHER modules exist (and where) is the resolver's job, not the walk's;
    // this boundary stop is the seam between those two responsibilities.
    let has_mod = @parse.has_mod(child)
    if has_mod {
      continue
    }
    walk(res, ctx, child, [..rel, name])
  }
}

///|
/// Gather one package_name's facts from its directory. Reads `moon.pkg`, lists the
/// source files, and resolves declared C stubs to absolute paths.
fn discover_one_package(
  ctx : ModuleCtx,
  abs : String,
  rel : Array[String],
) -> @model.DiscoveredPackage raise @model.DiscoverError {
  let fqn = @model.PackageFQN::{
    module_name: ctx.name,
    package_path: @model.PackagePath::from_segments(rel),
  }
  // Package manifest: DSL `moon.pkg`, else JSON `moon.pkg.json`.
  let entries = match @parse.load_pkg(abs) {
    Some(e) => e
    None =>
      raise @model.CantParsePackage(
        package_name=fqn.to_string(),
        path=abs + "/moon.pkg",
      )
  }
  let typed = @config.decode_pkg(entries) catch {
    e => raise @model.DecodePackage(package_name=fqn.to_string(), inner=e)
  }

  // Classify files in the package_name directory. `.mbt.md` must be tested before
  // `.mbt` since it does not end in `.mbt`, but we keep them clearly separate.
  let source_files : Array[String] = []
  let mbt_md_files : Array[String] = []
  // `.mbti` interface files present in the directory (bare names), for locating a
  // virtual package's contract below.
  let mbti_names : Set[String] = Set([])
  for entry in @os.list_dir(abs) {
    match entry {
      File(name) =>
        if name.has_suffix(".mbt.md") {
          mbt_md_files.push(abs + "/" + name)
        } else if name.has_suffix(".mbti") {
          mbti_names.add(name)
        } else if name.has_suffix(".mbt") {
          source_files.push(abs + "/" + name)
        }
      _ => ()
    }
  }

  // A virtual package's `.mbti` interface: prefer the newer `pkg.mbti`, else the
  // legacy `<short>.mbti`. Required when `virtual` is declared.
  let virtual_mbti : String? = match typed.virtual_pkg {
    Some(_) =>
      if mbti_names.contains("pkg.mbti") {
        Some(abs + "/pkg.mbti")
      } else if mbti_names.contains(fqn.short_alias() + ".mbti") {
        Some(abs + "/" + fqn.short_alias() + ".mbti")
      } else {
        raise @model.MissingVirtualMbtiFile(
          package_name=fqn.to_string(),
          dir=abs,
        )
      }
    None => None
  }
  let native_stub_files : Array[String] = []
  for stub in typed.native_stub {
    native_stub_files.push(abs + "/" + stub)
  }
  source_files.sort()
  mbt_md_files.sort()
  native_stub_files.sort()

  // Aliases re-exported via `pub using @alias` in this package's non-test sources.
  let reexport_aliases : Set[String] = Set([])
  for f in source_files {
    let is_test = f.has_suffix("_test.mbt") || f.has_suffix("_wbtest.mbt")
    if is_test {
      continue
    }
    let facts = ctx.scanner.scan(f)
    for a in facts.reexports {
      reexport_aliases.add(a)
    }
  }
  // Resolve each re-exported alias to the imported package's path. An import's
  // alias is its explicit `import_alias`, else the last segment of its path
  // (matching `PackageFQN::short_alias`). Aliases with no matching import are
  // dropped (a `pub using` on a stdlib alias needs no extra edge — the bundle
  // already provides it).
  let reexports : Array[String] = []
  for spec in typed.imports {
    let alias_name = match spec.import_alias {
      Some(a) => a
      None => last_path_segment(spec.path)
    }
    if reexport_aliases.contains(alias_name) {
      reexports.push(spec.path)
    }
  }
  @model.DiscoveredPackage::{
    root_path: abs,
    module_root: ctx.root,
    module_id: ctx.mid,
    fqn,
    source_files,
    mbt_md_files,
    native_stub_files,
    needs_translate_moonbit_h: typed.needs_translate_moonbit_h,
    imports: typed.imports,
    wbtest_imports: typed.wbtest_imports,
    test_imports: typed.test_imports,
    cond_imports: typed.cond_imports,
    module_prebuild: ctx.prebuild_script,
    reexports,
    // A package_name is `main` IFF its `moon.pkg` declares `options("is-main")`.
    // We deliberately do NOT treat a scanned top-level `fn main` as implicit main
    // (the old heuristic): the manifest is the single source of truth, matching the
    // current Rust engine (rupes-recta reads `pkg.raw.is_main` only). A package with
    // a `fn main` but no `is-main` is the author's mistake, not ours to guess.
    is_main: typed.is_main,
    // Resolve any `pre-build` entry that references a named `rule` into its
    // concrete command (package-local rules first, then the module's).
    prebuild: resolve_prebuild(
      fqn.to_string(),
      typed.prebuild,
      typed.local_rules,
      ctx.rules,
    ),
    targets: typed.targets,
    virtual_mbti,
    virtual_has_default: match typed.virtual_pkg {
      Some(vc) => vc.has_default
      None => false
    },
    implement: typed.implement,
    overrides: typed.overrides,
    sub_package: typed.sub_package,
    link: typed.link,
    is_linked: typed.is_linked,
    // Effective list = the module's CONCATENATED with the package's (module first).
    warn_list: cat_opt(ctx.warn, typed.warn_list),
    alert_list: cat_opt(ctx.alert, typed.alert_list),
    bin_name: typed.bin_name,
    bin_target: typed.bin_target,
    compile_flags: ctx.compile_flags,
    link_flags: ctx.link_flags,
    // Effective = the package's own `supported-targets` ∩ its module's.
    supported_targets: effective_supported(
      typed.supported_targets,
      ctx.supported,
    ),
    max_concurrent_tests: typed.max_concurrent_tests,
  }
}

///|
/// The last `/`-separated segment of a package path (`a/b/c` → `c`), i.e. the
/// default import alias when none is declared.
fn last_path_segment(path : String) -> String {
  match path.rev_split_once("/") {
    Some((_, last)) => last.to_owned()
    None => path
  }
}

///|
/// Concatenate two optional strings (the module-level value first, then the
/// package's), mirroring moon's `cat_opt`. Used to merge `warn-list`/`alert-list`.
fn cat_opt(a : String?, b : String?) -> String? {
  match (a, b) {
    (Some(x), Some(y)) => Some(x + y)
    (Some(x), None) => Some(x)
    (None, Some(y)) => Some(y)
    (None, None) => None
  }
}

///|
/// Resolve each `pre-build` entry's command: an inline `command` is kept as-is; a
/// named-`rule` entry is replaced by the command of the matching rule, looked up
/// FIRST in the package's own `rule` list, then the module's. An unresolved name
/// raises `UnknownPrebuildRule`.
fn resolve_prebuild(
  pkg_fqn : String,
  prebuild : Array[@config.PrebuildRule],
  local_rules : Array[@config.ModRule],
  mod_rules : Array[@config.ModRule],
) -> Array[@config.PrebuildRule] raise @model.DiscoverError {
  fn lookup(name : String) -> String? {
    for r in local_rules {
      if r.name == name {
        return Some(r.command)
      }
    }
    for r in mod_rules {
      if r.name == name {
        return Some(r.command)
      }
    }
    None
  }

  let out : Array[@config.PrebuildRule] = []
  for r in prebuild {
    match r.rule {
      None => out.push(r) // inline command
      Some(name) =>
        match lookup(name) {
          Some(cmd) => out.push({ ..r, command: cmd, rule: None })
          None =>
            raise @model.UnknownPrebuildRule(package_name=pkg_fqn, rule=name)
        }
    }
  }
  out
}

///|
/// Intersect a package's `supported-targets` with its module's. `None` means
/// "every backend", so it acts as the identity in the intersection.
fn effective_supported(
  pkg : Array[String]?,
  module_ : Array[String]?,
) -> Array[String]? {
  match (pkg, module_) {
    (None, m) => m
    (p, None) => p
    (Some(p), Some(m)) => Some(p.filter(fn(b) { m.contains(b) }))
  }
}
