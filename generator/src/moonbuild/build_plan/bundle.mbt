// `moon bundle`: build every package of the root module and merge their
// `.core`s into one `<module-last>.core` (`moonc bundle-core`).
//The plan uses the BUNDLE artifact
// layout (`cfg.bundle_of` set): per-package `.core`/`.mi` land at
// `<out>/<pkg-path>/<last>.{core,mi}`, so the output directory is directly
// consumable as a `-std-path` (it carries `prelude/prelude.mi`,
// `abort/abort.core`, `core.core`, …).

///|
/// Lower the root module (id 0) into a bundle plan. Mirrors moon's
/// `build_bundle`: every package compiles, but VIRTUAL packages contribute no
/// `.core` to the bundle input list — a virtual's default impl (e.g. core's
/// `abort`) ships as its own `<pkg>/<last>.core` next to the bundle instead,
/// and `link-core` fronts it separately.
pub fn bundle_plan(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  cfg : BuildConfig,
) -> Plan raise BuildPlanError {
  let deps_rel = deps_rel.specialize(cfg.backend.name(), cfg.target_platform)
  // Roots: every package of the root module.
  let roots : Array[@pkg_solve.BuildTarget] = []
  for pkg in packages.all_packages() {
    let @model.ModuleId(m) = pkg.module_id
    if m == 0 && pkg.supports(cfg.backend.name()) {
      match packages.get_package_id_by_name(pkg.fqn) {
        Some(id) => roots.push(@pkg_solve.BuildTarget::primary(id))
        None => ()
      }
    }
  }
  guard roots.length() > 0 else {
    raise PackageNotFound(fqn="<root module has no packages>")
  }
  let order = build_target_closure(deps_rel, roots) // deps before dependents
  gate_supported(packages, order, cfg)
  let actions : Map[String, @core.Action] = Map([])
  add_compile_actions(packages, deps_rel, order, cfg, actions)

  // The bundle's `.core` inputs: each root-module package's, in the topological
  // order `order` already carries (initializer order matters, like link-core).
  // Excluded: virtual packages (no `.core` of their own in the bundle — their
  // default impl ships separately), interface-only packages, and `SubPackage`
  // targets (their parent's full `.core` is already in).
  let cores : Array[String] = []
  let demand : Array[String] = []
  for bt in order {
    let p = packages.get_package(bt.pkg)
    let @model.ModuleId(m) = p.module_id
    guard m == 0 else { continue }
    let fqn = p.fqn
    // Every interface in this module is part of the reusable bundle, including
    // sub-package interfaces. Dependency-module artifacts stay in their own actions.
    demand.push(mi_path_t(cfg, fqn, bt.kind))
    guard bt.kind is Primary else { continue }
    if p.is_virtual() {
      // The interface `.mi` always ships; the default impl's `.core` too.
      if p.virtual_has_default {
        demand.push(core_path(cfg, fqn))
      }
    } else if p.has_implementation() {
      cores.push(core_path(cfg, fqn))
    }
  }
  let module_name = match cfg.bundle_of {
    Some(m) => m
    None => packages.get_package(roots[0].pkg).module_name
  }
  let out = cfg.out_dir + "/" + last_name_seg(module_name) + ".core"
  actions[out] = {
    primary_output: out,
    outputs: [out],
    inputs: cores.copy(),
    spec: @core.BundleCore(cores~),
  }
  demand.insert(0, out)
  Plan::make(actions, demand, build_env(cfg))
}
