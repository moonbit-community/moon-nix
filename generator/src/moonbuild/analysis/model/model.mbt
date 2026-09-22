// Data models for discovered packages.

///|
/// The on-disk facts about one package_name, gathered without interpreting them.
/// (Import resolution, test classification, and backend filtering belong to
/// later stages, not here.)
pub(all) struct DiscoveredPackage {
  /// Absolute path of the package_name directory in the source tree.
  root_path : String
  /// Absolute path of the owning module's root directory. Pre-build `$mod_dir` expands to this; codegen scripts (e.g.
  /// `$mod_dir/boot/foo.cjs`) live relative to it.
  module_root : String
  /// The module this package_name belongs to.
  module_id : ModuleId
  /// The package_name's fully-qualified name.
  fqn : PackageFQN
  /// `.mbt` source files (absolute paths, sorted). Unfiltered: `_test.mbt` and
  /// `_wbtest.mbt` are included and classified later.
  source_files : Array[String]
  mbt_md_files : Array[String]
  native_stub_files : Array[String]
  needs_translate_moonbit_h : Bool
  /// Imported packages (path + optional explicit import_alias), verbatim.
  imports : Array[@config.ImportSpec]
  /// Test-only imports, ADDITIONAL to [`imports`]: `wbtest_imports` are visible to
  /// the whitebox-test target, `test_imports` to the blackbox-test target.
  wbtest_imports : Array[@config.ImportSpec]
  test_imports : Array[@config.ImportSpec]
  /// Backend-conditional imports (`import {} for "<backend>"`), keyed by backend
  /// name. ADDITIONAL to [`imports`] when the active build backend matches. The
  /// solver tags their edges with `for_backend` so `specialize` keeps them only
  /// for that backend — so a leaf's other-backend imports don't poison its
  /// supported-targets.
  cond_imports : Map[String, Array[@config.ImportSpec]]
  /// The owning module's `--moonbit-unstable-prebuild` SCRIPT, as an ABSOLUTE path
  /// (resolved against `module_root` at discovery), or `None`. Module-level, so every
  /// package of a module carries the same value; build_plan runs it once per module
  /// and feeds its `link_configs` into the matching packages' native link.
  module_prebuild : String?
  /// Packages this one RE-EXPORTS via `pub using @alias {…}` (resolved to import
  /// paths). A consumer that imports this package and touches a re-exported item
  /// needs the re-exported package's `.mi` on the compile line even though it
  /// never imports it directly — the solver propagates these as implicit edges.
  /// Content-derived at discovery (the `pub using` lines are scanned from source).
  reexports : Array[String]
  /// Whether this package_name builds an executable (`options("is-main")`).
  is_main : Bool
  /// `pre-build` codegen rules (verbatim, package_name-relative paths). Their outputs
  /// become first-class source inputs to this package_name's compile step.
  prebuild : Array[@config.PrebuildRule]
  /// Per-file conditional-compilation expressions (`options("targets")`), keyed
  /// by bare filename. A source file absent here compiles for every target;
  /// build_plan filters `source_files` against the active target using these.
  targets : Map[String, @config.CondExpr]
  /// For a VIRTUAL package: the absolute path of its hand-written `.mbti`
  /// interface contract (`pkg.mbti`, or the legacy `<short>.mbti`). `None` = an
  /// ordinary package. The package's `.mi` is generated FROM this by
  /// `moonc build-interface`, not by `build-package`.
  virtual_mbti : String?
  /// For a virtual package: whether it also ships a DEFAULT implementation (its
  /// own `.mbt` source compiled to a `.core`, linked when a consumer gives no
  /// override). Meaningless unless [`virtual_mbti`] is `Some`.
  virtual_has_default : Bool
  /// `implement = "<virtual pkg path>"`: this package is the concrete
  /// IMPLEMENTATION of the named virtual package's interface. `None` = not an impl.
  implement : String?
  /// `overrides = [...]`: for a consumer, the implementation packages it selects to
  /// satisfy the virtual packages it imports.
  overrides : Array[String]
  /// `sub-package = { files, import }`: a SUB-PACKAGE — a subset of this package's
  /// files compiled separately with its own imports (cycle-breaking). `None` = no
  /// sub-package. The `files` paths are package-relative (resolved at lowering, as
  /// pre-build does); the `import`s are the sub-package's own (smaller) import list.
  sub_package : @config.SubPackageDecl?
  /// `"link": { ... }`: per-backend link settings (exports, wasm memory layout,
  /// js format, native cc overrides). On a non-main package this also marks it
  /// LINKABLE on the backends `@config.LinkConfig::need_link` says so — `moon
  /// build` then produces a library artifact for it. `None` = no link block.
  link : @config.LinkConfig?
  /// `"link": true`: link this package even though it is not `main` (carries no
  /// settings — the bool form is purely a force-link marker, moon's `force_link`).
  is_linked : Bool
  /// `warn-list` / `alert-list`: diagnostic control rendered to moonc `-w` /
  warn_list : String?
  /// `-alert`. `None` = compiler defaults.
  alert_list : String?
  /// `bin-name`: override the output executable's filename stem (main packages).
  bin_name : String?
  /// `bin-target`: the backend this binary builds for (overrides `--target`).
  bin_target : String?
  /// The OWNING MODULE's `compile-flags` / `link-flags` (moon.mod) — extra moonc
  /// args appended to this package's `build-package`/`check` (compile) and, for the
  /// link root, to `link-core` + the native `cc` link.
  compile_flags : Array[String]
  link_flags : Array[String]
  /// EFFECTIVE `supported-targets` (the package's own set ∩ its module's set),
  /// resolved to sorted backend names. `None` = every backend. A build for a
  /// backend not in this set is gated.
  supported_targets : Array[String]?
  /// `max-concurrent-tests` — cap on concurrent `async test`s, forwarded to the
  /// test driver. `None` = no cap.
  max_concurrent_tests : Int?
}

///|
/// Whether this package builds for `backend` (e.g. `"native"`). A package with no
/// `supported-targets` declaration supports every backend.
pub fn DiscoveredPackage::supports(
  self : DiscoveredPackage,
  backend : String,
) -> Bool {
  match self.supported_targets {
    None => true
    Some(set) => set.contains(backend)
  }
}

///|
/// Whether this package declares a sub-package (a separate `SubPackage` build
/// target compiling a file subset with its own imports).
pub fn DiscoveredPackage::has_sub_package(self : DiscoveredPackage) -> Bool {
  self.sub_package is Some(_)
}

///|
/// Whether this package is a virtual package (declares an interface via `.mbti`).
pub fn DiscoveredPackage::is_virtual(self : DiscoveredPackage) -> Bool {
  self.virtual_mbti is Some(_)
}

///|
/// Whether this package implements some OTHER virtual package's interface.
pub fn DiscoveredPackage::is_virtual_impl(self : DiscoveredPackage) -> Bool {
  self.implement is Some(_)
}

///|
/// Whether this package has MoonBit code to compile into a `.core` — every
/// ordinary package, plus a virtual package WITH a default implementation. A
/// virtual package without a default has only its interface (no `.core`).
pub fn DiscoveredPackage::has_implementation(self : DiscoveredPackage) -> Bool {
  match self.virtual_mbti {
    None => true
    Some(_) => self.virtual_has_default
  }
}

///|
pub fn DiscoveredPackage::config_path(self : DiscoveredPackage) -> String {
  self.root_path + "/moon.pkg"
}

///|
/// Whether this package has whitebox test sources (`_wbtest.mbt`), which compile
/// together WITH the package's own sources (seeing its private symbols) as a
/// separate `WhiteboxTest` build target. (`_wbtest.mbt` does not end in
/// `_test.mbt`, so it is never miscounted as blackbox.)
pub fn DiscoveredPackage::has_whitebox_tests(self : DiscoveredPackage) -> Bool {
  self.source_files.any(f => f.has_suffix("_wbtest.mbt"))
}

///|
/// Whether this package has blackbox test sources (`_test.mbt`), which compile as
/// a SEPARATE package importing the package-under-test through its public API — a
/// `BlackboxTest` build target.
pub fn DiscoveredPackage::has_blackbox_tests(self : DiscoveredPackage) -> Bool {
  self.source_files.any(f => f.has_suffix("_test.mbt"))
}

///|
/// Build-facing package facts. This intentionally stores rendered names and the
/// pieces needed by the build graph directly, so hot cache restore does not have
/// to reconstruct discovery-only `PackageFQN` objects.
pub(all) struct BuildPackage {
  root_path : String
  module_root : String
  module_id : ModuleId
  module_name : String
  package_segments : Array[String]
  package_path : String
  fqn : String
  short_alias : String
  source_files : Array[String]
  mbt_md_files : Array[String]
  native_stub_files : Array[String]
  needs_translate_moonbit_h : Bool
  imports : Array[@config.ImportSpec]
  wbtest_imports : Array[@config.ImportSpec]
  test_imports : Array[@config.ImportSpec]
  cond_imports : Map[String, Array[@config.ImportSpec]]
  module_prebuild : String?
  reexports : Array[String]
  is_main : Bool
  prebuild : Array[@config.PrebuildRule]
  targets : Map[String, @config.CondExpr]
  virtual_mbti : String?
  virtual_has_default : Bool
  implement : String?
  overrides : Array[String]
  sub_package : @config.SubPackageDecl?
  link : @config.LinkConfig?
  is_linked : Bool
  warn_list : String?
  alert_list : String?
  bin_name : String?
  bin_target : String?
  compile_flags : Array[String]
  link_flags : Array[String]
  supported_targets : Array[String]?
  max_concurrent_tests : Int?
}

///|
fn BuildPackage::from_discovered(
  modules : Array[String],
  pkg : DiscoveredPackage,
) -> BuildPackage? {
  let ModuleId(mi) = pkg.module_id
  guard mi >= 0 && mi < modules.length() else { return None }
  let module_name = modules[mi]
  let package_segments = pkg.fqn.package_path.segments
  let package_path = pkg.fqn.package_path.to_string()
  let fqn = pkg.fqn.to_string()
  Some({
    root_path: pkg.root_path,
    module_root: pkg.module_root,
    module_id: pkg.module_id,
    module_name,
    package_segments,
    package_path,
    fqn,
    short_alias: pkg.fqn.short_alias(),
    source_files: pkg.source_files,
    mbt_md_files: pkg.mbt_md_files,
    native_stub_files: pkg.native_stub_files,
    needs_translate_moonbit_h: pkg.needs_translate_moonbit_h,
    imports: pkg.imports,
    wbtest_imports: pkg.wbtest_imports,
    test_imports: pkg.test_imports,
    cond_imports: pkg.cond_imports,
    module_prebuild: pkg.module_prebuild,
    reexports: pkg.reexports,
    is_main: pkg.is_main,
    prebuild: pkg.prebuild,
    targets: pkg.targets,
    virtual_mbti: pkg.virtual_mbti,
    virtual_has_default: pkg.virtual_has_default,
    implement: pkg.implement,
    overrides: pkg.overrides,
    sub_package: pkg.sub_package,
    link: pkg.link,
    is_linked: pkg.is_linked,
    warn_list: pkg.warn_list,
    alert_list: pkg.alert_list,
    bin_name: pkg.bin_name,
    bin_target: pkg.bin_target,
    compile_flags: pkg.compile_flags,
    link_flags: pkg.link_flags,
    supported_targets: pkg.supported_targets,
    max_concurrent_tests: pkg.max_concurrent_tests,
  })
}

///|
fn split_package_path(path : String) -> Array[String] {
  if path == "" {
    return []
  }
  let segments : Array[String] = []
  let mut pos = 0
  for ;; {
    match path[pos:].find("/") {
      Some(rel) => {
        let next = pos + rel
        segments.push(path[pos:next].to_owned())
        pos = next + 1
      }
      None => {
        segments.push(path[pos:].to_owned())
        break
      }
    }
  }
  segments
}

///|
fn BuildPackage::to_discovered(self : BuildPackage) -> DiscoveredPackage {
  {
    root_path: self.root_path,
    module_root: self.module_root,
    module_id: self.module_id,
    fqn: {
      module_name: self.module_name,
      package_path: PackagePath::from_segments(self.package_segments),
    },
    source_files: self.source_files,
    mbt_md_files: self.mbt_md_files,
    native_stub_files: self.native_stub_files,
    needs_translate_moonbit_h: self.needs_translate_moonbit_h,
    imports: self.imports,
    wbtest_imports: self.wbtest_imports,
    test_imports: self.test_imports,
    cond_imports: self.cond_imports,
    module_prebuild: self.module_prebuild,
    reexports: self.reexports,
    is_main: self.is_main,
    prebuild: self.prebuild,
    targets: self.targets,
    virtual_mbti: self.virtual_mbti,
    virtual_has_default: self.virtual_has_default,
    implement: self.implement,
    overrides: self.overrides,
    sub_package: self.sub_package,
    link: self.link,
    is_linked: self.is_linked,
    warn_list: self.warn_list,
    alert_list: self.alert_list,
    bin_name: self.bin_name,
    bin_target: self.bin_target,
    compile_flags: self.compile_flags,
    link_flags: self.link_flags,
    supported_targets: self.supported_targets,
    max_concurrent_tests: self.max_concurrent_tests,
  }
}

///|
pub fn BuildPackage::supports(self : BuildPackage, backend : String) -> Bool {
  match self.supported_targets {
    None => true
    Some(set) => set.contains(backend)
  }
}

///|
pub fn BuildPackage::has_sub_package(self : BuildPackage) -> Bool {
  self.sub_package is Some(_)
}

///|
pub fn BuildPackage::is_virtual(self : BuildPackage) -> Bool {
  self.virtual_mbti is Some(_)
}

///|
pub fn BuildPackage::is_virtual_impl(self : BuildPackage) -> Bool {
  self.implement is Some(_)
}

///|
pub fn BuildPackage::has_implementation(self : BuildPackage) -> Bool {
  match self.virtual_mbti {
    None => true
    Some(_) => self.virtual_has_default
  }
}

///|
pub fn BuildPackage::config_path(self : BuildPackage) -> String {
  self.root_path + "/moon.pkg"
}

///|
pub fn BuildPackage::has_whitebox_tests(self : BuildPackage) -> Bool {
  self.source_files.any(f => f.has_suffix("_wbtest.mbt"))
}

///|
pub fn BuildPackage::has_blackbox_tests(self : BuildPackage) -> Bool {
  self.source_files.any(f => f.has_suffix("_test.mbt"))
}

///|
/// The result of discovery: an arena of packages plus the indices used to look
/// them up by id, by module, or by fully-qualified name.
pub struct DiscoverResult {
  /// All discovered packages; a [`PackageId`] is an index into this.
  packages : Array[DiscoveredPackage]
  /// Module names; a [`ModuleId`] is an index into this.
  modules : Array[String]
  /// FQN string -> package_name id. Also enforces global package_name-name uniqueness.
  rev_map : Map[String, PackageId]
  /// module index -> (package_name-path string -> package_name id).
  module_map : Map[Int, Map[String, PackageId]]
}

///|
pub fn DiscoverResult::new() -> DiscoverResult {
  { packages: [], modules: [], rev_map: {}, module_map: {} }
}

///|
/// Register a module by name, returning its fresh id.
pub fn DiscoverResult::add_module(
  self : DiscoverResult,
  name : String,
) -> ModuleId {
  let id = self.modules.length()
  self.modules.push(name)
  ModuleId(id)
}

///|
/// Add a discovered package_name.
pub fn DiscoverResult::add_package(
  self : DiscoverResult,
  m : ModuleId,
  pkg : DiscoveredPackage,
) -> PackageId raise DiscoverError {
  let fqn_str = pkg.fqn.to_string()
  match self.rev_map.get(fqn_str) {
    Some(prev) => {
      let PackageId(p) = prev
      raise ConflictingPackageName(
        first=self.packages[p].fqn.to_string(),
        second=fqn_str,
      )
    }
    None => ()
  }
  let id = PackageId(self.packages.length())
  let pkg_path = pkg.fqn.package_path.to_string()
  self.packages.push(pkg)
  self.rev_map[fqn_str] = id
  let ModuleId(mi) = m
  let inner = match self.module_map.get(mi) {
    Some(x) => x
    None => {
      let x : Map[String, PackageId] = Map([])
      self.module_map[mi] = x
      x
    }
  }
  inner[pkg_path] = id
  id
}

///|
/// Get a package_name by id. Total: ids are only minted by [`add_package`].
pub fn DiscoverResult::get_package(
  self : DiscoverResult,
  id : PackageId,
) -> DiscoveredPackage {
  let PackageId(i) = id
  self.packages[i]
}

///|
/// Look up a package_name id by its fully-qualified name string.
pub fn DiscoverResult::get_package_id_by_name(
  self : DiscoverResult,
  name : String,
) -> PackageId? {
  self.rev_map.get(name)
}

///|
pub fn DiscoverResult::all_packages(
  self : DiscoverResult,
) -> Array[DiscoveredPackage] {
  self.packages
}

///|
pub fn DiscoverResult::package_count(self : DiscoverResult) -> Int {
  self.packages.length()
}

///|
/// Build-facing package table. Unlike [`DiscoverResult`], this is shaped for the
/// build front-end: dense package ids, pre-rendered FQN strings, and root-module
/// package ids. It deliberately omits discovery-only indexes such as module_map.
pub struct BuildDiscovery {
  packages : Array[BuildPackage]
  modules : Array[String]
  rev_map : Map[String, PackageId]
  root_packages : Array[PackageId]
}

///|
pub fn BuildDiscovery::from_discover_result(
  res : DiscoverResult,
) -> BuildDiscovery {
  let packages : Array[BuildPackage] = []
  for pkg in res.packages {
    packages.push(BuildPackage::from_discovered(res.modules, pkg).unwrap())
  }
  BuildDiscovery::from_parts(res.modules, packages).unwrap()
}

///|
fn BuildDiscovery::from_parts(
  modules : Array[String],
  packages : Array[BuildPackage],
) -> BuildDiscovery? {
  let rev_map : Map[String, PackageId] = Map([])
  let root_packages : Array[PackageId] = []
  for i, pkg in packages {
    let ModuleId(mi) = pkg.module_id
    guard mi >= 0 && mi < modules.length() else { return None }
    let id = PackageId(i)
    rev_map[pkg.fqn] = id
    if mi == 0 {
      root_packages.push(id)
    }
  }
  Some({ packages, modules, rev_map, root_packages })
}

///|
pub fn BuildDiscovery::get_package(
  self : BuildDiscovery,
  id : PackageId,
) -> BuildPackage {
  let PackageId(i) = id
  self.packages[i]
}

///|
pub fn BuildDiscovery::get_fqn(self : BuildDiscovery, id : PackageId) -> String {
  let PackageId(i) = id
  self.packages[i].fqn
}

///|
pub fn BuildDiscovery::get_short_alias(
  self : BuildDiscovery,
  id : PackageId,
) -> String {
  let PackageId(i) = id
  self.packages[i].short_alias
}

///|
pub fn BuildDiscovery::can_import(
  self : BuildDiscovery,
  importer : PackageId,
  dependency : PackageId,
) -> Bool {
  let src = self.get_package(importer)
  let dst = self.get_package(dependency)
  can_import_segments(
    src.package_segments,
    dst.package_segments,
    src.module_id == dst.module_id,
  )
}

///|
pub fn BuildDiscovery::get_package_id_by_name(
  self : BuildDiscovery,
  name : String,
) -> PackageId? {
  self.rev_map.get(name)
}

///|
pub fn BuildDiscovery::all_packages(
  self : BuildDiscovery,
) -> Array[BuildPackage] {
  self.packages
}

///|
pub fn BuildDiscovery::package_count(self : BuildDiscovery) -> Int {
  self.packages.length()
}

///|
pub fn BuildDiscovery::root_package_ids(
  self : BuildDiscovery,
) -> Array[PackageId] {
  self.root_packages
}

///|
priv struct ImportSpecCompact {
  p : String
  a : String?
  s : Bool?
} derive(ToJson, FromJson)

///|
priv struct DiscoveredPackageCompact {
  r : String
  mr : String
  mid : Int
  f : String
  src : Array[String]
  md : Array[String]?
  ns : Array[String]?
  mh : Bool?
  i : Array[ImportSpecCompact]?
  wi : Array[ImportSpecCompact]?
  ti : Array[ImportSpecCompact]?
  ci : Map[String, Array[ImportSpecCompact]]?
  mp : String?
  re : Array[String]?
  main : Bool?
  pre : Array[@config.PrebuildRule]?
  tgt : Map[String, @config.CondExpr]?
  vmbti : String?
  vdef : Bool?
  im : String?
  over : Array[String]?
  sub : @config.SubPackageDecl?
  l : @config.LinkConfig?
  linked : Bool?
  warn : String?
  alert : String?
  bn : String?
  bt : String?
  cf : Array[String]?
  lf : Array[String]?
  st : Array[String]?
  mct : Int?
} derive(ToJson, FromJson)

///|
priv struct DiscoverCachePayload {
  m : Array[String]
  p : Array[DiscoveredPackageCompact]
} derive(ToJson, FromJson)

///|
fn[T] cache_array(xs : Array[T]) -> Array[T]? {
  if xs.is_empty() {
    None
  } else {
    Some(xs)
  }
}

///|
fn[V] cache_map(m : Map[String, V]) -> Map[String, V]? {
  if m.length() == 0 {
    None
  } else {
    Some(m)
  }
}

///|
fn cache_bool(b : Bool) -> Bool? {
  if b {
    Some(true)
  } else {
    None
  }
}

///|
fn cache_path(root : String, path : String) -> String {
  if path == root {
    "$"
  } else {
    let prefix = root + "/"
    if path.has_prefix(prefix) {
      "$/" + path[prefix.length():].to_owned()
    } else {
      path
    }
  }
}

///|
fn restore_cache_path(root : String, path : String) -> String {
  if path == "$" {
    root
  } else if path.has_prefix("$/") {
    root + "/" + path[2:].to_owned()
  } else {
    path
  }
}

///|
fn cache_path_array(root : String, paths : Array[String]) -> Array[String] {
  paths.map(fn(path) { cache_path(root, path) })
}

///|
fn restore_cache_path_array(
  root : String,
  paths : Array[String],
) -> Array[String] {
  paths.map(fn(path) { restore_cache_path(root, path) })
}

///|
fn cache_path_option(root : String, path : String?) -> String? {
  match path {
    Some(p) => Some(cache_path(root, p))
    None => None
  }
}

///|
fn restore_cache_path_option(root : String, path : String?) -> String? {
  match path {
    Some(p) => Some(restore_cache_path(root, p))
    None => None
  }
}

///|
fn cache_import_spec(imp : @config.ImportSpec) -> ImportSpecCompact {
  { p: imp.path, a: imp.import_alias, s: cache_bool(imp.sub_package) }
}

///|
fn restore_import_spec(imp : ImportSpecCompact) -> @config.ImportSpec {
  { path: imp.p, import_alias: imp.a, sub_package: imp.s.unwrap_or(false) }
}

///|
fn cache_import_array(
  imports : Array[@config.ImportSpec],
) -> Array[ImportSpecCompact]? {
  cache_array(imports.map(cache_import_spec))
}

///|
fn restore_import_array(
  imports : Array[ImportSpecCompact]?,
) -> Array[@config.ImportSpec] {
  imports.unwrap_or([]).map(restore_import_spec)
}

///|
fn cache_import_map(
  imports : Map[String, Array[@config.ImportSpec]],
) -> Map[String, Array[ImportSpecCompact]]? {
  let out : Map[String, Array[ImportSpecCompact]] = Map([])
  for k, v in imports {
    out[k] = v.map(cache_import_spec)
  }
  cache_map(out)
}

///|
fn restore_import_map(
  imports : Map[String, Array[ImportSpecCompact]]?,
) -> Map[String, Array[@config.ImportSpec]] {
  let out : Map[String, Array[@config.ImportSpec]] = Map([])
  for k, v in imports.unwrap_or({}) {
    out[k] = v.map(restore_import_spec)
  }
  out
}

///|
fn parse_cache_fqn(s : String) -> PackageFQN {
  let first = match s.find("/") {
    Some(i) => i
    None => return { module_name: s, package_path: PackagePath::empty() }
  }
  let rest_start = first + 1
  let second = match s[rest_start:].find("/") {
    Some(i) => rest_start + i
    None => return { module_name: s, package_path: PackagePath::empty() }
  }
  let module_name = s[:second].to_owned()
  let pkg_start = second + 1
  guard pkg_start < s.length() else {
    return { module_name, package_path: PackagePath::empty() }
  }
  let pkg_segments : Array[String] = []
  let mut pos = pkg_start
  for ;; {
    match s[pos:].find("/") {
      Some(rel) => {
        let next = pos + rel
        pkg_segments.push(s[pos:next].to_owned())
        pos = next + 1
      }
      None => {
        pkg_segments.push(s[pos:].to_owned())
        break
      }
    }
  }
  guard !pkg_segments.is_empty() else {
    return { module_name, package_path: PackagePath::empty() }
  }
  { module_name, package_path: PackagePath::from_segments(pkg_segments) }
}

///|
fn[T : ToJson] cache_json(value : T) -> String {
  value.to_json().stringify()
}

///|
fn[T : @json.FromJson] parse_cache_json(s : String) -> T? {
  let j = @json.parse(s) catch { _ => return None }
  Some(@json.from_json(j) catch { _ => return None })
}

///|
priv struct CacheReader {
  text : String
  mut pos : Int
}

///|
fn cache_write_int(sb : StringBuilder, n : Int) -> Unit {
  sb.write_string(n.to_string())
  sb.write_string(":")
}

///|
fn cache_write_string(sb : StringBuilder, s : String) -> Unit {
  cache_write_int(sb, s.length())
  sb.write_string(s)
}

///|
fn cache_write_bool(sb : StringBuilder, b : Bool) -> Unit {
  sb.write_string(if b { "T" } else { "F" })
}

///|
fn cache_write_string_option(sb : StringBuilder, s : String?) -> Unit {
  match s {
    Some(value) => {
      sb.write_string("S")
      cache_write_string(sb, value)
    }
    None => sb.write_string("N")
  }
}

///|
fn cache_write_int_option(sb : StringBuilder, n : Int?) -> Unit {
  match n {
    Some(value) => {
      sb.write_string("S")
      cache_write_int(sb, value)
    }
    None => sb.write_string("N")
  }
}

///|
fn cache_write_string_array(sb : StringBuilder, xs : Array[String]) -> Unit {
  cache_write_int(sb, xs.length())
  for x in xs {
    cache_write_string(sb, x)
  }
}

///|
fn cache_write_path_array(
  sb : StringBuilder,
  root : String,
  xs : Array[String],
) -> Unit {
  cache_write_int(sb, xs.length())
  for x in xs {
    cache_write_string(sb, cache_path(root, x))
  }
}

///|
fn cache_write_path_option(
  sb : StringBuilder,
  root : String,
  s : String?,
) -> Unit {
  cache_write_string_option(sb, cache_path_option(root, s))
}

///|
fn cache_write_string_array_option(
  sb : StringBuilder,
  xs : Array[String]?,
) -> Unit {
  match xs {
    Some(values) => {
      sb.write_string("S")
      cache_write_string_array(sb, values)
    }
    None => sb.write_string("N")
  }
}

///|
fn[T : ToJson] cache_write_json_option(sb : StringBuilder, value : T?) -> Unit {
  match value {
    Some(v) => {
      sb.write_string("S")
      cache_write_string(sb, cache_json(v))
    }
    None => sb.write_string("N")
  }
}

///|
fn cache_write_import(sb : StringBuilder, imp : @config.ImportSpec) -> Unit {
  cache_write_string(sb, imp.path)
  cache_write_string_option(sb, imp.import_alias)
  cache_write_bool(sb, imp.sub_package)
}

///|
fn cache_write_import_array(
  sb : StringBuilder,
  imports : Array[@config.ImportSpec],
) -> Unit {
  cache_write_int(sb, imports.length())
  for imp in imports {
    cache_write_import(sb, imp)
  }
}

///|
fn cache_write_import_map(
  sb : StringBuilder,
  imports : Map[String, Array[@config.ImportSpec]],
) -> Unit {
  cache_write_int(sb, imports.length())
  for k, v in imports {
    cache_write_string(sb, k)
    cache_write_import_array(sb, v)
  }
}

///|
fn cache_reader_read_byte(reader : CacheReader) -> Int? {
  guard reader.pos < reader.text.length() else { return None }
  let c = reader.text.code_unit_at(reader.pos).to_int()
  reader.pos = reader.pos + 1
  Some(c)
}

///|
fn cache_reader_read_int(reader : CacheReader) -> Int? {
  let mut n = 0
  let mut saw_digit = false
  for ;; {
    guard reader.pos < reader.text.length() else { return None }
    let c = reader.text.code_unit_at(reader.pos).to_int()
    if c == ':'.to_int() {
      guard saw_digit else { return None }
      reader.pos = reader.pos + 1
      return Some(n)
    }
    guard c >= '0'.to_int() && c <= '9'.to_int() else { return None }
    saw_digit = true
    n = n * 10 + (c - '0'.to_int())
    reader.pos = reader.pos + 1
  }
}

///|
fn cache_reader_read_string(reader : CacheReader) -> String? {
  let n = match cache_reader_read_int(reader) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 && reader.pos + n <= reader.text.length() else { return None }
  let s = reader.text[reader.pos:reader.pos + n].to_owned()
  reader.pos = reader.pos + n
  Some(s)
}

///|
fn cache_reader_read_bool(reader : CacheReader) -> Bool? {
  match cache_reader_read_byte(reader) {
    Some(c) if c == 'T'.to_int() => Some(true)
    Some(c) if c == 'F'.to_int() => Some(false)
    _ => None
  }
}

///|
fn cache_reader_read_string_option(reader : CacheReader) -> String?? {
  match cache_reader_read_byte(reader) {
    Some(c) if c == 'N'.to_int() => Some(None)
    Some(c) if c == 'S'.to_int() =>
      match cache_reader_read_string(reader) {
        Some(s) => Some(Some(s))
        None => None
      }
    _ => None
  }
}

///|
fn cache_reader_read_int_option(reader : CacheReader) -> Int?? {
  match cache_reader_read_byte(reader) {
    Some(c) if c == 'N'.to_int() => Some(None)
    Some(c) if c == 'S'.to_int() =>
      match cache_reader_read_int(reader) {
        Some(n) => Some(Some(n))
        None => None
      }
    _ => None
  }
}

///|
fn cache_reader_read_string_array(reader : CacheReader) -> Array[String]? {
  let n = match cache_reader_read_int(reader) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 else { return None }
  let xs : Array[String] = []
  for _ in 0..<n {
    match cache_reader_read_string(reader) {
      Some(s) => xs.push(s)
      None => return None
    }
  }
  Some(xs)
}

///|
fn cache_reader_read_path_array(
  reader : CacheReader,
  root : String,
) -> Array[String]? {
  match cache_reader_read_string_array(reader) {
    Some(xs) => Some(restore_cache_path_array(root, xs))
    None => None
  }
}

///|
fn cache_reader_read_path_option(
  reader : CacheReader,
  root : String,
) -> String?? {
  match cache_reader_read_string_option(reader) {
    Some(value) => Some(restore_cache_path_option(root, value))
    None => None
  }
}

///|
fn cache_reader_read_string_array_option(
  reader : CacheReader,
) -> Array[String]?? {
  match cache_reader_read_byte(reader) {
    Some(c) if c == 'N'.to_int() => Some(None)
    Some(c) if c == 'S'.to_int() =>
      match cache_reader_read_string_array(reader) {
        Some(xs) => Some(Some(xs))
        None => None
      }
    _ => None
  }
}

///|
fn[T : @json.FromJson] cache_reader_read_json_option(
  reader : CacheReader,
) -> T?? {
  match cache_reader_read_string_option(reader) {
    Some(None) => Some(None)
    Some(Some(text)) =>
      match parse_cache_json(text) {
        Some(v) => Some(Some(v))
        None => None
      }
    None => None
  }
}

///|
fn cache_reader_read_import(reader : CacheReader) -> @config.ImportSpec? {
  let path = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let import_alias = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let sub_package = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  Some({ path, import_alias, sub_package })
}

///|
fn cache_reader_read_import_array(
  reader : CacheReader,
) -> Array[@config.ImportSpec]? {
  let n = match cache_reader_read_int(reader) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 else { return None }
  let imports : Array[@config.ImportSpec] = []
  for _ in 0..<n {
    match cache_reader_read_import(reader) {
      Some(imp) => imports.push(imp)
      None => return None
    }
  }
  Some(imports)
}

///|
fn cache_reader_read_import_map(
  reader : CacheReader,
) -> Map[String, Array[@config.ImportSpec]]? {
  let n = match cache_reader_read_int(reader) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 else { return None }
  let imports : Map[String, Array[@config.ImportSpec]] = Map([])
  for _ in 0..<n {
    let key = match cache_reader_read_string(reader) {
      Some(s) => s
      None => return None
    }
    let value = match cache_reader_read_import_array(reader) {
      Some(v) => v
      None => return None
    }
    imports[key] = value
  }
  Some(imports)
}

///|
fn BuildPackage::write_cache_v1(
  self : BuildPackage,
  sb : StringBuilder,
  root : String,
) -> Unit {
  cache_write_string(sb, cache_path(root, self.root_path))
  cache_write_string(sb, cache_path(root, self.module_root))
  cache_write_int(sb, self.module_id.0)
  cache_write_string(sb, self.module_name)
  cache_write_string(sb, self.package_path)
  cache_write_string(sb, self.fqn)
  cache_write_string(sb, self.short_alias)
  cache_write_path_array(sb, root, self.source_files)
  cache_write_path_array(sb, root, self.mbt_md_files)
  cache_write_path_array(sb, root, self.native_stub_files)
  cache_write_bool(sb, self.needs_translate_moonbit_h)
  cache_write_import_array(sb, self.imports)
  cache_write_import_array(sb, self.wbtest_imports)
  cache_write_import_array(sb, self.test_imports)
  cache_write_import_map(sb, self.cond_imports)
  cache_write_path_option(sb, root, self.module_prebuild)
  cache_write_string_array(sb, self.reexports)
  cache_write_bool(sb, self.is_main)
  cache_write_json_option(sb, cache_array(self.prebuild))
  cache_write_json_option(sb, cache_map(self.targets))
  cache_write_path_option(sb, root, self.virtual_mbti)
  cache_write_bool(sb, self.virtual_has_default)
  cache_write_string_option(sb, self.implement)
  cache_write_string_array(sb, self.overrides)
  cache_write_json_option(sb, self.sub_package)
  cache_write_json_option(sb, self.link)
  cache_write_bool(sb, self.is_linked)
  cache_write_string_option(sb, self.warn_list)
  cache_write_string_option(sb, self.alert_list)
  cache_write_string_option(sb, self.bin_name)
  cache_write_string_option(sb, self.bin_target)
  cache_write_string_array(sb, self.compile_flags)
  cache_write_string_array(sb, self.link_flags)
  cache_write_string_array_option(sb, self.supported_targets)
  cache_write_int_option(sb, self.max_concurrent_tests)
}

///|
fn cache_reader_read_build_package_v1(
  reader : CacheReader,
  root : String,
  modules : Array[String],
) -> BuildPackage? {
  let root_path = match cache_reader_read_string(reader) {
    Some(s) => restore_cache_path(root, s)
    None => return None
  }
  let module_root = match cache_reader_read_string(reader) {
    Some(s) => restore_cache_path(root, s)
    None => return None
  }
  let module_id = match cache_reader_read_int(reader) {
    Some(n) => ModuleId(n)
    None => return None
  }
  let ModuleId(mi) = module_id
  guard mi >= 0 && mi < modules.length() else { return None }
  let module_name = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  guard module_name == modules[mi] else { return None }
  let package_path = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let fqn = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let short_alias = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let package_segments = split_package_path(package_path)
  let source_files = match cache_reader_read_path_array(reader, root) {
    Some(xs) => xs
    None => return None
  }
  let mbt_md_files = match cache_reader_read_path_array(reader, root) {
    Some(xs) => xs
    None => return None
  }
  let native_stub_files = match cache_reader_read_path_array(reader, root) {
    Some(xs) => xs
    None => return None
  }
  let needs_translate_moonbit_h = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  let imports = match cache_reader_read_import_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let wbtest_imports = match cache_reader_read_import_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let test_imports = match cache_reader_read_import_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let cond_imports = match cache_reader_read_import_map(reader) {
    Some(m) => m
    None => return None
  }
  let module_prebuild = match cache_reader_read_path_option(reader, root) {
    Some(value) => value
    None => return None
  }
  let reexports = match cache_reader_read_string_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let is_main = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  let prebuild : Array[@config.PrebuildRule] = match
    cache_reader_read_json_option(reader) {
    Some(Some(xs)) => xs
    Some(None) => []
    None => return None
  }
  let targets : Map[String, @config.CondExpr] = match
    cache_reader_read_json_option(reader) {
    Some(Some(m)) => m
    Some(None) => {}
    None => return None
  }
  let virtual_mbti = match cache_reader_read_path_option(reader, root) {
    Some(value) => value
    None => return None
  }
  let virtual_has_default = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  let implement = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let overrides = match cache_reader_read_string_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let sub_package : @config.SubPackageDecl? = match
    cache_reader_read_json_option(reader) {
    Some(value) => value
    None => return None
  }
  let link : @config.LinkConfig? = match cache_reader_read_json_option(reader) {
    Some(value) => value
    None => return None
  }
  let is_linked = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  let warn_list = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let alert_list = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let bin_name = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let bin_target = match cache_reader_read_string_option(reader) {
    Some(value) => value
    None => return None
  }
  let compile_flags = match cache_reader_read_string_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let link_flags = match cache_reader_read_string_array(reader) {
    Some(xs) => xs
    None => return None
  }
  let supported_targets = match cache_reader_read_string_array_option(reader) {
    Some(value) => value
    None => return None
  }
  let max_concurrent_tests = match cache_reader_read_int_option(reader) {
    Some(value) => value
    None => return None
  }
  Some({
    root_path,
    module_root,
    module_id,
    module_name,
    package_segments,
    package_path,
    fqn,
    short_alias,
    source_files,
    mbt_md_files,
    native_stub_files,
    needs_translate_moonbit_h,
    imports,
    wbtest_imports,
    test_imports,
    cond_imports,
    module_prebuild,
    reexports,
    is_main,
    prebuild,
    targets,
    virtual_mbti,
    virtual_has_default,
    implement,
    overrides,
    sub_package,
    link,
    is_linked,
    warn_list,
    alert_list,
    bin_name,
    bin_target,
    compile_flags,
    link_flags,
    supported_targets,
    max_concurrent_tests,
  })
}

///|
fn DiscoveredPackage::to_compact_cache(
  self : DiscoveredPackage,
  root : String,
) -> DiscoveredPackageCompact {
  {
    r: cache_path(root, self.root_path),
    mr: cache_path(root, self.module_root),
    mid: self.module_id.0,
    f: self.fqn.to_string(),
    src: cache_path_array(root, self.source_files),
    md: cache_array(cache_path_array(root, self.mbt_md_files)),
    ns: cache_array(cache_path_array(root, self.native_stub_files)),
    mh: cache_bool(self.needs_translate_moonbit_h),
    i: cache_import_array(self.imports),
    wi: cache_import_array(self.wbtest_imports),
    ti: cache_import_array(self.test_imports),
    ci: cache_import_map(self.cond_imports),
    mp: cache_path_option(root, self.module_prebuild),
    re: cache_array(self.reexports),
    main: cache_bool(self.is_main),
    pre: cache_array(self.prebuild),
    tgt: cache_map(self.targets),
    vmbti: cache_path_option(root, self.virtual_mbti),
    vdef: cache_bool(self.virtual_has_default),
    im: self.implement,
    over: cache_array(self.overrides),
    sub: self.sub_package,
    l: self.link,
    linked: cache_bool(self.is_linked),
    warn: self.warn_list,
    alert: self.alert_list,
    bn: self.bin_name,
    bt: self.bin_target,
    cf: cache_array(self.compile_flags),
    lf: cache_array(self.link_flags),
    st: self.supported_targets,
    mct: self.max_concurrent_tests,
  }
}

///|
fn DiscoveredPackageCompact::to_package(
  self : DiscoveredPackageCompact,
  root : String,
) -> DiscoveredPackage {
  {
    root_path: restore_cache_path(root, self.r),
    module_root: restore_cache_path(root, self.mr),
    module_id: ModuleId(self.mid),
    fqn: parse_cache_fqn(self.f),
    source_files: restore_cache_path_array(root, self.src),
    mbt_md_files: restore_cache_path_array(root, self.md.unwrap_or([])),
    native_stub_files: restore_cache_path_array(root, self.ns.unwrap_or([])),
    needs_translate_moonbit_h: self.mh.unwrap_or(false),
    imports: restore_import_array(self.i),
    wbtest_imports: restore_import_array(self.wi),
    test_imports: restore_import_array(self.ti),
    cond_imports: restore_import_map(self.ci),
    module_prebuild: restore_cache_path_option(root, self.mp),
    reexports: self.re.unwrap_or([]),
    is_main: self.main.unwrap_or(false),
    prebuild: self.pre.unwrap_or([]),
    targets: self.tgt.unwrap_or({}),
    virtual_mbti: restore_cache_path_option(root, self.vmbti),
    virtual_has_default: self.vdef.unwrap_or(false),
    implement: self.im,
    overrides: self.over.unwrap_or([]),
    sub_package: self.sub,
    link: self.l,
    is_linked: self.linked.unwrap_or(false),
    warn_list: self.warn,
    alert_list: self.alert,
    bin_name: self.bn,
    bin_target: self.bt,
    compile_flags: self.cf.unwrap_or([]),
    link_flags: self.lf.unwrap_or([]),
    supported_targets: self.st,
    max_concurrent_tests: self.mct,
  }
}

///|
fn DiscoverResult::from_cache_parts(
  modules : Array[String],
  packages : Array[DiscoveredPackage],
) -> DiscoverResult? {
  let rev_map : Map[String, PackageId] = Map([])
  let module_map : Map[Int, Map[String, PackageId]] = Map([])
  for i, pkg in packages {
    let ModuleId(mi) = pkg.module_id
    guard mi >= 0 && mi < modules.length() else { return None }
    let id = PackageId(i)
    rev_map[pkg.fqn.to_string()] = id
    let inner = match module_map.get(mi) {
      Some(x) => x
      None => {
        let x : Map[String, PackageId] = Map([])
        module_map[mi] = x
        x
      }
    }
    inner[pkg.fqn.package_path.to_string()] = id
  }
  Some({ packages, modules, rev_map, module_map })
}

///|
pub fn DiscoverResult::to_cache_json_text(
  self : DiscoverResult,
  root : String,
) -> String {
  let payload : DiscoverCachePayload = {
    m: self.modules,
    p: self.packages.map(pkg => pkg.to_compact_cache(root)),
  }
  cache_json(payload)
}

///|
pub fn DiscoverResult::from_cache_json_text(
  text : String,
  root : String,
) -> DiscoverResult? {
  let payload : DiscoverCachePayload = match parse_cache_json(text) {
    Some(p) => p
    None => return None
  }
  let packages = payload.p.map(pkg => pkg.to_package(root))
  DiscoverResult::from_cache_parts(payload.m, packages)
}

///|
pub fn DiscoverResult::to_cache_text(
  self : DiscoverResult,
  root : String,
) -> String {
  BuildDiscovery::from_discover_result(self).to_cache_text(root)
}

///|
pub fn BuildDiscovery::to_cache_text(
  self : BuildDiscovery,
  root : String,
) -> String {
  let sb = StringBuilder()
  cache_write_string_array(sb, self.modules)
  cache_write_int(sb, self.packages.length())
  for pkg in self.packages {
    pkg.write_cache_v1(sb, root)
  }
  sb.to_string()
}

///|
pub fn DiscoverResult::from_cache_text(
  text : String,
  root : String,
) -> DiscoverResult? {
  let r = { text, pos: 0 }
  let modules = match cache_reader_read_string_array(r) {
    Some(xs) => xs
    None => return None
  }
  let n = match cache_reader_read_int(r) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 else { return None }
  let packages : Array[DiscoveredPackage] = []
  for _ in 0..<n {
    match cache_reader_read_build_package_v1(r, root, modules) {
      Some(pkg) => packages.push(pkg.to_discovered())
      None => return None
    }
  }
  guard r.pos == text.length() else { return None }
  DiscoverResult::from_cache_parts(modules, packages)
}

///|
pub fn BuildDiscovery::from_cache_text(
  text : String,
  root : String,
) -> BuildDiscovery? {
  let r = { text, pos: 0 }
  let modules = match cache_reader_read_string_array(r) {
    Some(xs) => xs
    None => return None
  }
  let n = match cache_reader_read_int(r) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 else { return None }
  let packages : Array[BuildPackage] = []
  for _ in 0..<n {
    match cache_reader_read_build_package_v1(r, root, modules) {
      Some(pkg) => packages.push(pkg)
      None => return None
    }
  }
  guard r.pos == text.length() else { return None }
  BuildDiscovery::from_parts(modules, packages)
}

///|
/// Raised by the discovery process. Mirrors moonbuild's `DiscoverError`, kept to
/// the cases moon's MVP can actually hit.
pub(all) suberror DiscoverError {
  /// No readable `moon.mod` at the module root.
  CantReadModuleFile(path~ : String)
  /// `moon.mod` parsed but failed to decode into a typed manifest.
  DecodeModule(path~ : String, inner~ : @config.DecodeError)
  /// `moon.pkg` did not parse as the DSL.
  CantParsePackage(package_name~ : String, path~ : String)
  /// `moon.pkg` parsed but failed to decode into a typed manifest.
  DecodePackage(package_name~ : String, inner~ : @config.DecodeError)
  /// Two packages resolved to the same fully-qualified name.
  ConflictingPackageName(first~ : String, second~ : String)
  /// A package declares `virtual` but has no `.mbti` interface file alongside it.
  MissingVirtualMbtiFile(package_name~ : String, dir~ : String)
  /// A `pre-build` entry references a `rule` name defined in neither the package's
  /// `rule` list nor its module's.
  UnknownPrebuildRule(package_name~ : String, rule~ : String)
}
