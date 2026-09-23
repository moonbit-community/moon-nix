// Data models for discovered packages.

///|
/// Package facts shared across discovery, import resolution, and planning.
pub(all) struct Package {
  root_path : String
  module_root : String
  module_id : ModuleId
  module_name : String
  /// Segments within the module, used to enforce internal-package visibility.
  package_segments : Array[String]
  package_path : String
  fqn : String
  short_alias : String
  /// Unfiltered sources; planning excludes test files and inactive targets.
  source_files : Array[String]
  mbt_md_files : Array[String]
  native_stub_files : Array[String]
  needs_translate_moonbit_h : Bool
  imports : Array[@config.ImportSpec]
  wbtest_imports : Array[@config.ImportSpec]
  test_imports : Array[@config.ImportSpec]
  cond_imports : Map[String, Array[@config.ImportSpec]]
  /// Retained for future prebuild export; the CLI currently rejects declarations.
  module_prebuild : String?
  /// Import paths re-exported by source-level `pub using` declarations.
  reexports : Array[String]
  is_main : Bool
  prebuild : Array[@config.PrebuildRule]
  targets : Map[String, @config.CondExpr]
  /// A virtual interface has its own producing action, separate from its default implementation.
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
pub fn Package::supports(self : Package, backend : String) -> Bool {
  match self.supported_targets {
    None => true
    Some(set) => set.contains(backend)
  }
}

///|
pub fn Package::has_sub_package(self : Package) -> Bool {
  self.sub_package is Some(_)
}

///|
pub fn Package::is_virtual(self : Package) -> Bool {
  self.virtual_mbti is Some(_)
}

///|
pub fn Package::is_virtual_impl(self : Package) -> Bool {
  self.implement is Some(_)
}

///|
pub fn Package::has_implementation(self : Package) -> Bool {
  match self.virtual_mbti {
    None => true
    Some(_) => self.virtual_has_default
  }
}

///|
pub fn Package::config_path(self : Package) -> String {
  self.root_path + "/moon.pkg"
}

///|
/// Shared package table for discovery, dependency solving, and build planning.
/// Package IDs index the facts directly; names are indexed once during discovery.
pub struct PackageTable {
  packages : Array[Package]
  modules : Array[(String, String, String)] // raw name, identity, FQN prefix
  module_edges : Map[String, Map[String, String]]
  rev_map : Map[String, PackageId]
  root_packages : Array[PackageId]
}

///|
pub fn PackageTable::get_package(
  self : PackageTable,
  id : PackageId,
) -> Package {
  let PackageId(i) = id
  self.packages[i]
}

///|
pub fn PackageTable::get_fqn(self : PackageTable, id : PackageId) -> String {
  let PackageId(i) = id
  self.packages[i].fqn
}

///|
pub fn PackageTable::get_short_alias(
  self : PackageTable,
  id : PackageId,
) -> String {
  let PackageId(i) = id
  self.packages[i].short_alias
}

///|
pub fn PackageTable::can_import(
  self : PackageTable,
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
pub fn PackageTable::get_package_id_by_name(
  self : PackageTable,
  name : String,
) -> PackageId? {
  self.rev_map.get(name)
}

///|
/// Resolve an import in its declaring module's dependency context. Two
/// incompatible versions can have the same source-level package path while
/// carrying distinct version-qualified build identities.
pub fn PackageTable::get_package_id_for_import(
  self : PackageTable,
  importer : PackageId,
  path : String,
) -> PackageId? {
  let src = self.get_package(importer)
  let ModuleId(src_index) = src.module_id
  let (_, src_key, _) = self.modules[src_index]
  let mut target_name = ""
  for entry in self.modules {
    let (name, _, _) = entry
    if (path == name || path.has_prefix(name + "/")) && name.length() > target_name.length() {
      target_name = name
    }
  }
  if target_name == "" { return self.rev_map.get(path) }
  let mut target_key : String? = None
  if target_name == src.module_name {
    target_key = Some(src_key)
  } else {
    match self.module_edges.get(src_key) {
      Some(deps) =>
        match deps.get(target_name) {
          Some(version) => target_key = Some(target_name + "@" + version)
          None => ()
        }
      None => ()
    }
  }
  if !self.module_edges.is_empty() && target_key is None {
    return None
  }
  for entry in self.modules {
    let (name, key, prefix) = entry
    if name == target_name && (target_key is None || target_key == Some(key)) {
      return self.rev_map.get(prefix + path[target_name.length():].to_owned())
    }
  }
  None
}

///|
pub fn PackageTable::all_packages(self : PackageTable) -> Array[Package] {
  self.packages
}

///|
pub fn PackageTable::package_count(self : PackageTable) -> Int {
  self.packages.length()
}

///|
pub fn PackageTable::root_package_ids(self : PackageTable) -> Array[PackageId] {
  self.root_packages
}

///|
pub fn PackageTable::new(
  module_edges? : Map[String, Map[String, String]] = Map([]),
) -> PackageTable {
  { packages: [], modules: [], module_edges, rev_map: {}, root_packages: [], }
}

///|
pub fn PackageTable::add_module(
  self : PackageTable,
  name : String,
  version? : String = "",
  versioned? : Bool = false,
) -> ModuleId {
  let id = ModuleId(self.modules.length())
  let key = name + "@" + version
  self.modules.push((name, key, if versioned { key } else { name }))
  id
}

///|
pub fn PackageTable::add_package(
  self : PackageTable,
  module_id : ModuleId,
  pkg : Package,
) -> PackageId raise DiscoverError {
  if self.rev_map.contains(pkg.fqn) {
    raise ConflictingPackageName(first=pkg.fqn, second=pkg.fqn)
  }
  let id = PackageId(self.packages.length())
  self.packages.push(pkg)
  self.rev_map[pkg.fqn] = id
  if module_id == ModuleId(0) {
    self.root_packages.push(id)
  }
  id
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
