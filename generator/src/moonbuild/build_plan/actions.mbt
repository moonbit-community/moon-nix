// The `moonc` action builders: turn one solved package_name (or the whole closure)
// into a structured `@core.Action`. Paths are resolved here; the command is
// rendered downstream from the spec (`render_command`). Native C steps live
// in `actions_native.mbt`.

///|
fn effective_warn_list(pkg : @model.Package) -> String? {
  let @model.ModuleId(m) = pkg.module_id
  if m != 0 {
    Some(pkg.warn_list.unwrap_or("") + "-a")
  } else if pkg.warn_list is Some("") {
    None
  } else {
    pkg.warn_list
  }
}

///|
/// The `build-package` action for one package_path: compile its sources (handwritten
/// plus any pre-build–generated ones, deduped) and the `.mi` of each direct
/// dependency into a `.core`.
fn build_core_action(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  generated : Array[String],
  vimpl : @core.VirtualImpl?,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let core = core_path(cfg, fqn)
  let sources = compile_sources(pkg, generated, cfg)

  // A virtual package's OWN default impl (`vimpl` set, `is_impl=false`) must not
  // re-emit the `.mi` — its `build-interface` owns it. (A foreign impl,
  // `is_impl=true`, emits its own throwaway `.mi`.)
  let no_mi = match vimpl {
    Some(v) => !v.is_impl
    None => false
  }

  // Scheduling inputs: all compile sources (so generated ones pull in their
  // pre-build action) + each dependency's `.core` (a `sub-package: true` import
  // depends on the dep's `_sub.core`) — EXCEPT a dependency that is a virtual
  // package, where we depend on its interface `.mi` instead (the consumer compiles
  // against the interface; a no-default virtual has no `.core` — the inline barrier).
  let inputs = sources.copy()
  for entry in deps_rel.deps_of_target(@pkg_solve.BuildTarget::primary(pkg_id)) {
    let (to, _) = entry
    let dfqn = packages.get_fqn(to.pkg)
    if packages.get_package(to.pkg).is_virtual() {
      inputs.push(mi_path_t(cfg, dfqn, to.kind))
    } else {
      inputs.push(core_path_t(cfg, dfqn, to.kind))
    }
  }
  // An implementation (or default impl) also depends on the virtual interface
  // `.mi` it is checked against (`-check-mi`), so the interface builds first.
  match vimpl {
    Some(v) => inputs.push(v.mi)
    None => ()
  }
  // Bundles let moonc load transitive interfaces through `-all-pkgs`.
  // Include their producing artifacts so every interface is ready before compile.
  if cfg.bundle_of is Some(_) {
    let direct : Array[@pkg_solve.BuildTarget] = []
    for
      entry in deps_rel.deps_of_target(@pkg_solve.BuildTarget::primary(pkg_id)) {
      direct.push(entry.0)
    }
    let seen : Set[String] = Set([])
    for f in inputs {
      seen.add(f)
    }
    for bt in build_target_closure(deps_rel, direct) {
      let dep = packages.get_package(bt.pkg)
      let dfqn = packages.get_fqn(bt.pkg)
      let artifact = if dep.is_virtual() {
        mi_path_t(cfg, dfqn, bt.kind)
      } else {
        core_path_t(cfg, dfqn, bt.kind)
      }
      if !seen.contains(artifact) {
        seen.add(artifact)
        inputs.push(artifact)
      }
    }
  }

  // Structured imports — paths resolved here, but the command is rendered
  // downstream (`render_command`) from the spec.
  let dep_imports = collect_dep_imports(
    packages,
    deps_rel,
    @pkg_solve.BuildTarget::primary(pkg_id),
    cfg,
  )
  let std_imports = collect_std_imports(packages, pkg.imports, cfg)
  let outputs = if no_mi { [core] } else { [core, mi_path(cfg, fqn)] }
  {
    primary_output: core,
    // `moonc build-package` also emits the `.mi` artifact — cache them together,
    // unless `-no-mi` suppresses it (default-impl virtual).
    outputs,
    inputs,
    spec: @core.Compile(
      sources~,
      fqn~,
      is_main=pkg.is_main,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=dep_imports,
      std_imports~,
      pkg_root=pkg.root_path,
      workspace=if cfg.bundle_of is Some(_) {
        Some(pkg.module_root)
      } else {
        None
      },
      // Bundle plans run in workspace mode, like moon's bundle commands.
      all_pkgs=Some(all_pkgs_path(cfg)),
      virtual_impl=vimpl,
      no_mi~,
      warn_list=effective_warn_list(pkg),
      alert_list=pkg.alert_list,
      compile_flags=pkg.compile_flags,
    ),
  }
}

///|
/// The `build-interface` action for a VIRTUAL package: generate its interface
/// `.mi` from the hand-written `.mbti` contract. Consumers import this `.mi`
/// exactly like any dependency's; the package's `build-package` (if it has a
/// default impl) is a SEPARATE action producing the `.core`.
fn build_interface_action(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let mbti = pkg.virtual_mbti.unwrap() // caller guarantees `is_virtual()`
  let src = @pkg_solve.BuildTarget::primary(pkg_id)
  let dep_imports = collect_dep_imports(packages, deps_rel, src, cfg)

  // Inputs: the `.mbti` contract + each interface dependency's `.mi`.
  let inputs : Array[String] = [mbti]
  for entry in deps_rel.deps_of_target(src) {
    let (to, _) = entry
    inputs.push(mi_path_t(cfg, packages.get_fqn(to.pkg), to.kind))
  }
  {
    primary_output: mi_path(cfg, fqn),
    outputs: [mi_path(cfg, fqn)],
    inputs,
    spec: @core.BuildInterface(
      mbti~,
      fqn~,
      pkg_root=pkg.root_path,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=dep_imports,
    ),
  }
}

///|
/// The virtual-package wiring for `pkg_id`'s `build-package`, if any:
///   - a virtual package WITH a default impl checks its default against its own
///     interface `.mi` (`is_impl = false`);
///   - a package implementing a foreign virtual checks against THAT virtual's
///     interface `.mi` (`is_impl = true`).
/// `None` for ordinary packages (and no-default virtuals, which never compile).
fn compile_virtual_impl(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
) -> @core.VirtualImpl? {
  let pkg = packages.get_package(pkg_id)
  if pkg.is_virtual() {
    if pkg.virtual_has_default {
      let fqn = packages.get_fqn(pkg_id)
      Some({
        mi: mi_path(cfg, fqn),
        pkg_name: fqn,
        pkg_root: pkg.root_path,
        is_impl: false,
      })
    } else {
      None
    }
  } else {
    match deps_rel.virt_impl_of(pkg_id) {
      Some(impl_id) => {
        let v = packages.get_package(impl_id)
        let vfqn = packages.get_fqn(impl_id)
        Some({
          mi: mi_path(cfg, vfqn),
          pkg_name: vfqn,
          pkg_root: v.root_path,
          is_impl: true,
        })
      }
      None =>
        match deps_rel.std_virt_impl_of(pkg_id) {
          Some(fqn) => std_virtual_impl(cfg.std, fqn)
          None => None
        }
    }
  }
}

///|
fn std_virtual_impl(std : StdConfig?, fqn : String) -> @core.VirtualImpl? {
  match std {
    Some(std) =>
      match fqn {
        "moonbitlang/core/abort" =>
          Some({
            mi: std.bundle + "/abort/abort.mi",
            pkg_name: fqn,
            pkg_root: std.core_root + "/abort",
            is_impl: true,
          })
        _ => None
      }
    None => None
  }
}

///|
/// The `build-package` action for a SUB-PACKAGE target: compile the
/// declared `files` SUBSET with the sub-package's OWN (smaller) import list,
/// producing `<flat>_sub.core`/`<flat>_sub.mi`. The `moonc -pkg` name is the
/// PARENT package's fqn (only the artifact files carry `_sub`), so a consumer that
/// imported `{ path, "sub-package": true }` links these `_sub` artifacts in place
/// of the heavier `Primary` ones — the cycle-breaking trick.
fn sub_core_action(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let sub = pkg.sub_package.unwrap() // caller guarantees `has_sub_package()`
  let target = @pkg_solve.BuildTarget::{ pkg: pkg_id, kind: SubPackage, }
  // The sub-package's files are package-relative; resolve to absolute (like the
  // pre-build rules do). No conditional-compilation filtering — the subset is
  // explicit.
  let sources = sub.files.map(fn(f) { pkg.root_path + "/" + f })
  let core = core_path_t(cfg, fqn, SubPackage)
  let mi = mi_path_t(cfg, fqn, SubPackage)

  let inputs = sources.copy()
  for entry in deps_rel.deps_of_target(target) {
    let (to, _) = entry
    let dfqn = packages.get_fqn(to.pkg)
    if packages.get_package(to.pkg).is_virtual() {
      inputs.push(mi_path_t(cfg, dfqn, to.kind))
    } else {
      inputs.push(core_path_t(cfg, dfqn, to.kind))
    }
  }
  {
    primary_output: core,
    outputs: [core, mi],
    inputs,
    spec: @core.Compile(
      sources~,
      fqn~, // PARENT name: moonc `-pkg` has no `_sub` suffix
      is_main=false,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=collect_dep_imports(packages, deps_rel, target, cfg),
      std_imports=collect_std_imports(packages, sub.imports, cfg),
      pkg_root=pkg.root_path,
      workspace=if cfg.bundle_of is Some(_) {
        Some(pkg.module_root)
      } else {
        None
      },
      all_pkgs=Some(all_pkgs_path(cfg)),
      virtual_impl=None,
      no_mi=false,
      warn_list=effective_warn_list(pkg),
      alert_list=pkg.alert_list,
      compile_flags=pkg.compile_flags,
    ),
  }
}

///|
/// The `link-core` action: link every package_name's `.core` (in `order`) into the
/// final executable for `main`.
fn link_core_action(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  main : @model.PackageId,
  cfg : BuildConfig,
  overrides : Map[@model.PackageId, @model.PackageId],
  std_overrides : Map[String, @model.PackageId],
) -> @core.Action raise BuildPlanError {
  let main_pkg = packages.get_package(main)
  let main_fqn = packages.get_fqn(main)
  let exe = exe_path(cfg, main_fqn, main_pkg.bin_name)
  let inputs : Array[String] = []
  let cores : Array[String] = []
  let std_abort_overridden = std_overrides.contains("moonbitlang/core/abort")

  // The link order, with each overridden virtual package already substituted by
  // its chosen implementation package.
  let order = link_core_order(deps_rel, main, overrides)

  // Standard-library cores front the inputs (and the render links them first).
  match cfg.std {
    Some(std) => {
      if !std_abort_overridden {
        inputs.push(std.bundle + "/abort/abort.core")
      }
      inputs.push(std.bundle + "/core.core")
      if std_abort_overridden {
        cores.push(std.bundle + "/core.core")
      }
    }
    None => ()
  }
  let pkg_sources : Array[(String, String)] = []
  fn add_pkg_core(bt : @pkg_solve.BuildTarget) -> Unit raise BuildPlanError {
    let p = packages.get_package(bt.pkg)
    // A virtual package that survived substitution (no override) must have its own
    // default `.core`; otherwise there is nothing to link in its place. (Only a
    // `Primary` target can be virtual.)
    if bt.kind is Primary && p.is_virtual() && !p.virtual_has_default {
      raise NoImplementation(virtual_pkg=packages.get_fqn(bt.pkg))
    }
    // A `SubPackage` target links its `_sub.core`; a `Primary` target its `.core`.
    let fqn = packages.get_fqn(bt.pkg)
    let c = core_path_t(cfg, fqn, bt.kind)
    inputs.push(c)
    cores.push(c)
    pkg_sources.push((fqn, p.root_path))
  }
  for bt in order {
    add_pkg_core(bt)
  }
  for _std_virtual_fqn, impl_pkg_id in std_overrides {
    add_pkg_core(@pkg_solve.BuildTarget::primary(impl_pkg_id))
  }
  {
    primary_output: exe,
    outputs: [exe],
    inputs,
    spec: @core.LinkCore(
      std_bundle=if std_abort_overridden {
        None
      } else {
        cfg.std.map(fn(s) { s.bundle })
      },
      cores~,
      main=main_fqn,
      // moon reads the link root's manifest link config from here too (`moon.pkg.json`
      // lives at the package's root_path), alongside the explicit switches below.
      pkg_config=Some(main_pkg.root_path + "/moon.pkg.json"),
      pkg_sources~,
      std_core_root=cfg.std.map(fn(s) { s.core_root }),
      // The link root's manifest `link` block, filtered to the active backend.
      exported_functions=link_exports(main_pkg, cfg.backend),
      js_format=link_js_format(main_pkg, cfg.backend),
      wasm_opts=link_wasm_opts(main_pkg, cfg.backend),
      // Module `link-flags` (from the link root's owning module).
      link_flags=main_pkg.link_flags,
      // "New native": when set, link-core lowers to a `.o` for this host triple.
    ),
  }
}
