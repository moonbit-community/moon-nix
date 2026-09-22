// The `moonc` action builders: turn one solved package_name (or the whole closure)
// into a structured `@core.Action`. Paths are resolved here; the command is
// rendered downstream from the spec (`@core.Action::command`). Native C steps live
// in `actions_native.mbt`.

///|
/// The effective `-w` warn-list for a package's compile. Third-party DEPENDENCY
/// packages (anything outside the root module, id 0) get `-a` appended to SUPPRESS
/// their warnings: you can't fix a dependency's source, so its warnings are pure
/// noise on every build . `-a` comes LAST so
/// it overrides whatever the package itself set. Root-module packages keep their own
/// list unchanged.
fn effective_warn_list(pkg : @model.BuildPackage, cfg : BuildConfig) -> String? {
  let @model.ModuleId(m) = pkg.module_id
  if m != 0 {
    // Dependency: suppress its warnings (`-a`, last so it wins).
    Some(pkg.warn_list.unwrap_or("") + "-a")
  } else {
    // Root module: package `warnings` config, then the CLI `--warn-list` spec
    // (cumulative left-to-right in moonc `-w`), then `--deny-warn`'s `@a` promotion.
    let spec = pkg.warn_list.unwrap_or("") + cfg.cli_warn_list.unwrap_or("")
    let spec = if cfg.deny_warnings { spec + "@a" } else { spec }
    if spec == "" {
      None
    } else {
      Some(spec)
    }
  }
}

///|
fn workspace_path(cfg : BuildConfig, pkg : @model.BuildPackage) -> String? {
  if cfg.workspace_layout ||
    cfg.mono_module is Some(_) ||
    cfg.bundle_of is Some(_) {
    Some(pkg.module_root)
  } else {
    None
  }
}

///|
priv struct CheckPathCache {
  fqns : Array[String]
  mis : Array[String]
  sub_mis : Array[String]
  all_pkgs : String
  std_bundle : String?
  platform_flags : Array[String]
}

///|
fn pkg_index(id : @model.PackageId) -> Int {
  let @model.PackageId(i) = id
  i
}

///|
fn make_check_path_cache(
  packages : @model.BuildDiscovery,
  cfg : BuildConfig,
) -> CheckPathCache {
  let fqns : Array[String] = []
  let mis : Array[String] = []
  let sub_mis : Array[String] = []
  for i in 0..<packages.package_count() {
    let fqn = packages.get_fqn(@model.PackageId(i))
    fqns.push(fqn)
    mis.push(mi_path(cfg, fqn))
    sub_mis.push(mi_path_t(cfg, fqn, SubPackage))
  }
  {
    fqns,
    mis,
    sub_mis,
    all_pkgs: all_pkgs_path(cfg),
    std_bundle: cfg.std.map(fn(s) { s.bundle }),
    platform_flags: platform_cfg(cfg),
  }
}

///|
fn CheckPathCache::fqn(self : CheckPathCache, id : @model.PackageId) -> String {
  self.fqns[pkg_index(id)]
}

///|
fn CheckPathCache::mi(self : CheckPathCache, id : @model.PackageId) -> String {
  self.mis[pkg_index(id)]
}

///|
fn CheckPathCache::mi_t(
  self : CheckPathCache,
  id : @model.PackageId,
  kind : @pkg_solve.TargetKind,
) -> String {
  match kind {
    SubPackage => self.sub_mis[pkg_index(id)]
    _ => self.mis[pkg_index(id)]
  }
}

///|
fn collect_dep_imports_check_cached(
  deps_rel : @pkg_solve.DepRelationship,
  target : @pkg_solve.BuildTarget,
  cache : CheckPathCache,
) -> Array[@core.MiDep] {
  let out : Array[@core.MiDep] = []
  for entry in deps_rel.deps_of_target(target) {
    let (to, edge) = entry
    out.push({ mi: cache.mi_t(to.pkg, to.kind), import_alias: edge.short_alias })
  }
  out
}

///|
fn collect_dep_imports_check_packed(
  deps : @pkg_solve.PackedCheckDeps,
  target : @pkg_solve.BuildTarget,
  cache : CheckPathCache,
) -> Array[@core.MiDep] {
  let out : Array[@core.MiDep] = []
  for edge in deps.deps_of_target(target) {
    out.push({
      mi: cache.mi_t(edge.to, edge.kind),
      import_alias: edge.short_alias,
    })
  }
  out
}

///|
/// The `build-package` action for one package_path: compile its sources (handwritten
/// plus any pre-build–generated ones, deduped) and the `.mi` of each direct
/// dependency into a `.core`.
fn build_core_action(
  packages : @model.BuildDiscovery,
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
  // Workspace mode (`-all-pkgs`, bundle plans): moonc may lazily load ANY
  // transitive dependency's `.mi` to resolve a trait referenced through a dep's
  // signature, so the whole TRANSITIVE closure joins the inputs — hashed (cache
  // soundness: the `.mi` is a cached-together byproduct of the `.core` we hash)
  // and ordered (the closure is acyclic, so no scheduling cycle). Inputs must be
  // PRIMARY artifacts (the scheduler keys actions by primary output): a virtual
  // dependency's interface `.mi`, every other package's `.core`. Ordinary
  // builds keep the direct-deps-only graph.
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
  // downstream (`@core.Action::command`) from the spec.
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
      check=false,
      sources~,
      fqn~,
      is_main=pkg.is_main,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=dep_imports,
      std_imports~,
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      // Bundle plans run in workspace mode, like moon's bundle commands.
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(all_pkgs_path(cfg)),
      coverage=cfg.coverage,
      value_tracing=cfg.value_tracing,
      virtual_impl=vimpl,
      no_mi~,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..platform_cfg(cfg)],
    ),
  }
}

///|
/// The `build-interface` action for a VIRTUAL package: generate its interface
/// `.mi` from the hand-written `.mbti` contract. Consumers import this `.mi`
/// exactly like any dependency's; the package's `build-package` (if it has a
/// default impl) is a SEPARATE action producing the `.core`.
fn build_interface_action(
  packages : @model.BuildDiscovery,
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
fn build_interface_action_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  cache : CheckPathCache,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let mbti = pkg.virtual_mbti.unwrap()
  let src = @pkg_solve.BuildTarget::primary(pkg_id)
  let dep_imports = collect_dep_imports_check_packed(deps, src, cache)

  let inputs : Array[String] = [mbti]
  for edge in deps.deps_of_target(src) {
    inputs.push(mi_path_t(cfg, packages.get_fqn(edge.to), edge.kind))
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
/// The virtual-package wiring for `pkg_id`'s `build-package`/`check`, if any:
///   - a virtual package WITH a default impl checks its default against its own
///     interface `.mi` (`is_impl = false`);
///   - a package implementing a foreign virtual checks against THAT virtual's
///     interface `.mi` (`is_impl = true`).
/// `None` for ordinary packages (and no-default virtuals, which never compile).
fn compile_virtual_impl(
  packages : @model.BuildDiscovery,
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
fn compile_virtual_impl_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
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
    match deps.virt_impl_of(pkg_id) {
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
        match deps.std_virt_impl_of(pkg_id) {
          Some(fqn) => std_virtual_impl(cfg.std, fqn)
          None => None
        }
    }
  }
}

///|
/// The `check` action for one package_path: type-check its sources against the `.mi` of each direct dependency,
/// producing this package_name's `.mi`. Like `build-package` but emits `moonc check`
/// to a `.mi` (no `.core`).
fn check_action(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  generated : Array[String],
  vimpl : @core.VirtualImpl?,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let mi = mi_path(cfg, fqn)
  let sources = compile_sources(pkg, generated, cfg)

  // Scheduling inputs: compile sources + each dependency's `.mi` (the artifact a
  // dependency's own check / interface produces — a pure `.mi -> .mi` graph; a
  // `sub-package: true` import points at the dep's `_sub.mi`).
  let inputs = sources.copy()
  for entry in deps_rel.deps_of_target(@pkg_solve.BuildTarget::primary(pkg_id)) {
    let (to, _) = entry
    inputs.push(mi_path_t(cfg, packages.get_fqn(to.pkg), to.kind))
  }
  // An implementation also checks against the virtual interface `.mi`.
  match vimpl {
    Some(v) => inputs.push(v.mi)
    None => ()
  }

  // Same structured spec as a build, but `check=true` → `.mi`, never links. (A
  // `fn main` package_name is still flagged `-is-main` when checking — `moonc check`
  // rejects it otherwise, E4069 — which the renderer emits from `is_main`.)
  {
    primary_output: mi,
    outputs: [mi], // `check` produces only the primary `.mi`
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn~,
      is_main=pkg.is_main,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=collect_dep_imports(
        packages,
        deps_rel,
        @pkg_solve.BuildTarget::primary(pkg_id),
        cfg,
      ),
      std_imports=collect_std_imports(packages, pkg.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      // Workspace mode under a no-std/bundle plan (e.g. checking moonbitlang/core):
      // moonc lazily loads other packages' `.mi` from `-all-pkgs` to resolve the
      // implicit prelude and traits reached through a dependency's signature (e.g.
      // `@test.assert_eq`'s `T : @debug.Debug` bound). Flat plans leave both `None`.
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(all_pkgs_path(cfg)),
      coverage=false,
      value_tracing=false,
      virtual_impl=vimpl,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..platform_cfg(cfg)],
    ),
  }
}

///|
fn check_test_action(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  t : @pkg_solve.BuildTarget,
  cfg : BuildConfig,
  generated : Array[String],
) -> @core.Action {
  let pkg = packages.get_package(t.pkg)
  let fqn = packages.get_fqn(t.pkg)
  let pkg_sources = compile_sources(pkg, generated, cfg)
  let (driver_kind, test_pkg, sources, doctest_only, imports) = match t.kind {
    @pkg_solve.WhiteboxTest =>
      (
        @core.Whitebox,
        fqn,
        [..pkg_sources, ..files_with_suffix(pkg, cfg, "_wbtest.mbt")],
        [],
        [..pkg.imports, ..pkg.wbtest_imports],
      )
    @pkg_solve.InlineTest => (@core.Internal, fqn, pkg_sources, [], pkg.imports)
    _ => {
      let bb_sources = [
        ..files_with_suffix(pkg, cfg, "_test.mbt"),
        ..pkg.mbt_md_files,
      ]
      (
        @core.Blackbox,
        fqn + "_blackbox_test",
        bb_sources,
        pkg_sources,
        [..pkg.imports, ..pkg.test_imports],
      )
    }
  }
  let inputs = [..sources, ..doctest_only]
  let dep_imports : Array[@core.MiDep] = []
  for entry in deps_rel.deps_of_target(t) {
    let (dep, edge) = entry
    let mi = mi_path_t(cfg, packages.get_fqn(dep.pkg), dep.kind)
    inputs.push(mi)
    dep_imports.push({ mi, import_alias: edge.short_alias })
  }
  let mi = mi_path_t(cfg, fqn, t.kind)
  {
    primary_output: mi,
    outputs: [mi],
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn=test_pkg,
      is_main=pkg.is_main && t.kind != @pkg_solve.BlackboxTest,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=dep_imports,
      std_imports=collect_std_imports(packages, imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=Some(driver_kind),
      doctest_only~,
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(all_pkgs_path(cfg)),
      coverage=false,
      value_tracing=false,
      virtual_impl=None,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..platform_cfg(cfg)],
    ),
  }
}

///|
fn check_action_cached(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  cache : CheckPathCache,
  generated : Array[String],
  vimpl : @core.VirtualImpl?,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = cache.fqn(pkg_id)
  let mi = cache.mi(pkg_id)
  let sources = compile_sources(pkg, generated, cfg)
  let target = @pkg_solve.BuildTarget::primary(pkg_id)

  let inputs = sources.copy()
  for entry in deps_rel.deps_of_target(target) {
    let (to, _) = entry
    inputs.push(cache.mi_t(to.pkg, to.kind))
  }
  match vimpl {
    Some(v) => inputs.push(v.mi)
    None => ()
  }

  {
    primary_output: mi,
    outputs: [mi],
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn~,
      is_main=pkg.is_main,
      std_bundle=cache.std_bundle,
      deps=collect_dep_imports_check_cached(deps_rel, target, cache),
      std_imports=collect_std_imports(packages, pkg.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(cache.all_pkgs),
      coverage=false,
      value_tracing=false,
      virtual_impl=vimpl,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..cache.platform_flags],
    ),
  }
}

///|
fn check_action_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  cache : CheckPathCache,
  generated : Array[String],
  vimpl : @core.VirtualImpl?,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = cache.fqn(pkg_id)
  let mi = cache.mi(pkg_id)
  let sources = compile_sources(pkg, generated, cfg)
  let target = @pkg_solve.BuildTarget::primary(pkg_id)

  let inputs = sources.copy()
  for edge in deps.deps_of_target(target) {
    inputs.push(cache.mi_t(edge.to, edge.kind))
  }
  match vimpl {
    Some(v) => inputs.push(v.mi)
    None => ()
  }

  {
    primary_output: mi,
    outputs: [mi],
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn~,
      is_main=pkg.is_main,
      std_bundle=cache.std_bundle,
      deps=collect_dep_imports_check_packed(deps, target, cache),
      std_imports=collect_std_imports(packages, pkg.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(cache.all_pkgs),
      coverage=false,
      value_tracing=false,
      virtual_impl=vimpl,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..cache.platform_flags],
    ),
  }
}

///|
/// The `build-package` (or `check`) action for a SUB-PACKAGE target: compile the
/// declared `files` SUBSET with the sub-package's OWN (smaller) import list,
/// producing `<flat>_sub.core`/`<flat>_sub.mi`. The `moonc -pkg` name is the
/// PARENT package's fqn (only the artifact files carry `_sub`), so a consumer that
/// imported `{ path, "sub-package": true }` links these `_sub` artifacts in place
/// of the heavier `Primary` ones — the cycle-breaking trick.
fn sub_core_action(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  check~ : Bool,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = packages.get_fqn(pkg_id)
  let sub = pkg.sub_package.unwrap() // caller guarantees `has_sub_package()`
  let target = @pkg_solve.BuildTarget::{ pkg: pkg_id, kind: SubPackage }
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
    } else if check {
      inputs.push(mi_path_t(cfg, dfqn, to.kind))
    } else {
      inputs.push(core_path_t(cfg, dfqn, to.kind))
    }
  }
  {
    primary_output: if check {
      mi
    } else {
      core
    },
    outputs: if check {
      [mi]
    } else {
      [core, mi]
    },
    inputs,
    spec: @core.Compile(
      check~,
      sources~,
      fqn~, // PARENT name: moonc `-pkg` has no `_sub` suffix
      is_main=false,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=collect_dep_imports(packages, deps_rel, target, cfg),
      std_imports=collect_std_imports(packages, sub.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(all_pkgs_path(cfg)),
      coverage=false,
      value_tracing=false,
      virtual_impl=None,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..platform_cfg(cfg)],
    ),
  }
}

///|
fn sub_check_action_cached(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  cache : CheckPathCache,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = cache.fqn(pkg_id)
  let sub = pkg.sub_package.unwrap()
  let target = @pkg_solve.BuildTarget::{ pkg: pkg_id, kind: SubPackage }
  let sources = sub.files.map(fn(f) { pkg.root_path + "/" + f })
  let mi = cache.mi_t(pkg_id, SubPackage)

  let inputs = sources.copy()
  for entry in deps_rel.deps_of_target(target) {
    let (to, _) = entry
    inputs.push(cache.mi_t(to.pkg, to.kind))
  }
  {
    primary_output: mi,
    outputs: [mi],
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn~,
      is_main=false,
      std_bundle=cache.std_bundle,
      deps=collect_dep_imports_check_cached(deps_rel, target, cache),
      std_imports=collect_std_imports(packages, sub.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(cache.all_pkgs),
      coverage=false,
      value_tracing=false,
      virtual_impl=None,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..cache.platform_flags],
    ),
  }
}

///|
fn sub_check_action_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
  pkg_id : @model.PackageId,
  cfg : BuildConfig,
  cache : CheckPathCache,
) -> @core.Action {
  let pkg = packages.get_package(pkg_id)
  let fqn = cache.fqn(pkg_id)
  let sub = pkg.sub_package.unwrap()
  let target = @pkg_solve.BuildTarget::{ pkg: pkg_id, kind: SubPackage }
  let sources = sub.files.map(fn(f) { pkg.root_path + "/" + f })
  let mi = cache.mi_t(pkg_id, SubPackage)

  let inputs = sources.copy()
  for edge in deps.deps_of_target(target) {
    inputs.push(cache.mi_t(edge.to, edge.kind))
  }
  {
    primary_output: mi,
    outputs: [mi],
    inputs,
    spec: @core.Compile(
      check=true,
      sources~,
      fqn~,
      is_main=false,
      std_bundle=cache.std_bundle,
      deps=collect_dep_imports_check_packed(deps, target, cache),
      std_imports=collect_std_imports(packages, sub.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=None,
      doctest_only=[],
      workspace=workspace_path(cfg, pkg),
      all_pkgs=Some(cache.all_pkgs),
      coverage=false,
      value_tracing=false,
      virtual_impl=None,
      no_mi=false,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..cache.platform_flags],
    ),
  }
}

///|
/// The `link-core` action: link every package_name's `.core` (in `order`) into the
/// final executable for `main`.
fn link_core_action(
  packages : @model.BuildDiscovery,
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
  // The `<out>.map` source map (debug on wasm/js) is a `link-core` byproduct; cache
  // it as an output so a warm-cache HIT into a fresh `_build` restores it too
  // (else `moon run --target js` loses source-mapped stack traces after a rebuild).
  let outputs : Array[String] = if emits_source_map(cfg) {
    [exe, exe + ".map"]
  } else {
    [exe]
  }
  {
    primary_output: exe,
    outputs,
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
      test_mode=false,
      // The link root's manifest `link` block, filtered to the active backend.
      exported_functions=link_exports(main_pkg, cfg.backend),
      js_format=link_js_format(main_pkg, cfg.backend),
      wasm_opts=link_wasm_opts(main_pkg, cfg.backend),
      // Module `link-flags` (from the link root's owning module).
      link_flags=main_pkg.link_flags,
      // "New native": when set, link-core lowers to a `.o` for this host triple.
      native_target=cfg.native_target,
      output_wat=cfg.output_wat,
    ),
  }
}

///|
/// Cross-build `-cfg` flags for `moonc build-package`: when the native target OS
/// is Windows (a cross build — `cc` carries `-target …-windows-…`), set
/// `platform=windows` so `#cfg(platform=…)` code (e.g. moonbitlang/async) compiles
/// the Windows OS paths to match the Windows-compiled C stubs. Without it moonc
/// defaults `platform` to the host (the unix paths), which then fail to link
/// against the cross-compiled C. Empty for a native (host) build — unchanged.
fn platform_cfg(cfg : BuildConfig) -> Array[String] {
  match cfg.backend {
    Native(Some(nc)) | Llvm(Some(nc)) =>
      if @cc.target_of(nc.cc) is Windows {
        ["-cfg", "platform=windows"]
      } else {
        []
      }
    _ => []
  }
}
