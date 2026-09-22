// The plan entry points: lower a solved dependency graph into a `Plan` (a
// map of artifact path -> `@core.Action` + the root artifact). Each flavor starts from its target(s) and pulls in exactly the dependency
// closure. The per-stage machinery lives alongside: traverse / sources /
// prebuild / actions(_native) / layout.

///|
/// Lower the executable rooted at `main_fqn` into a concrete [`Plan`].
/// Produces one `build-package` action per package_name in `main_fqn`'s dependency
/// closure, and one `link-core` action linking them into the final artifact.
pub fn build_plan(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  main_fqn : String,
  cfg : BuildConfig,
) -> Plan raise BuildPlanError {
  root_plan(packages, deps_rel, [main_fqn], [], cfg)
}

///|
/// Lower a mixed set of executable and library roots in one shared graph. The
/// executable roots get link/native executable actions; library roots are demanded
/// as their `.core` outputs.
pub fn root_plan(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  main_fqns : Array[String],
  lib_fqns : Array[String],
  cfg : BuildConfig,
) -> Plan raise BuildPlanError {
  // Specialize the (condition-agnostic) dep graph to THIS build's backend + platform:
  // drop every `import {} for "<other-backend>"` / `for "<other-os>"` edge so all
  // downstream traversals (closure, compile imports, link order) see only the imports
  // that apply now.
  let deps_rel = deps_rel.specialize(cfg.backend.name(), cfg.target_platform)
  let main_pkg_ids : Array[@model.PackageId] = []
  let lib_pkg_ids : Array[@model.PackageId] = []
  let all_roots : Array[@pkg_solve.BuildTarget] = []
  for main_fqn in main_fqns {
    let main_pkg_id = match packages.get_package_id_by_name(main_fqn) {
      Some(id) => id
      None => raise PackageNotFound(fqn=main_fqn)
    }
    main_pkg_ids.push(main_pkg_id)
    all_roots.push(@pkg_solve.BuildTarget::primary(main_pkg_id))
    // The consumer's virtual-package override selections (virtual -> impl).
    for _virtual_pid, impl_pkg_id in deps_rel.overrides_of(main_pkg_id) {
      // Implementations are never imported, so the override must pull them in.
      all_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
    for _std_virtual_fqn, impl_pkg_id in deps_rel.std_overrides_of(main_pkg_id) {
      all_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
  }
  for lib_fqn in lib_fqns {
    let lib_pkg_id = match packages.get_package_id_by_name(lib_fqn) {
      Some(id) => id
      None => raise PackageNotFound(fqn=lib_fqn)
    }
    lib_pkg_ids.push(lib_pkg_id)
    all_roots.push(@pkg_solve.BuildTarget::primary(lib_pkg_id))
  }
  let all_order = build_target_closure(deps_rel, all_roots) // deps before dependents
  gate_supported(packages, all_order, cfg)
  let actions : Map[String, @core.Action] = Map([])
  add_compile_actions(packages, deps_rel, all_order, cfg, actions, check=false)
  let roots : Array[String] = []
  for lib_pkg_id in lib_pkg_ids {
    roots.push(core_path(cfg, packages.get_fqn(lib_pkg_id)))
  }

  match cfg.backend.native_config() {
    Some(nc) =>
      for act in runtime_actions(cfg, nc) {
        actions[act.primary_output] = act
      }
    None => ()
  }

  for main_pkg_id in main_pkg_ids {
    let overrides = deps_rel.overrides_of(main_pkg_id)
    let std_overrides = deps_rel.std_overrides_of(main_pkg_id)
    let action_roots = [@pkg_solve.BuildTarget::primary(main_pkg_id)]
    for _virtual_pid, impl_pkg_id in overrides {
      action_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
    for _std_virtual_fqn, impl_pkg_id in std_overrides {
      action_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
    let order = build_target_closure(deps_rel, action_roots)
    // LinkCore: emits the final `.wasm` (wasm) or an intermediate `.c` (native).
    let link = link_core_action(
      packages, deps_rel, main_pkg_id, cfg, overrides, std_overrides,
    )
    actions[link.primary_output] = link
    let main_fqn = packages.get_fqn(main_pkg_id)
    match cfg.backend.native_config() {
      // wasm-gc: link-core's output IS the artifact.
      None => roots.push(link.primary_output)
      // native: compile the runtime + C stubs, then cc everything into an exe.
      Some(nc) => {
        let stub_libs : Array[String] = []
        // Each stub-owning package's `stub-cc-link-flags` (link-time libs the stub
        // needs, e.g. `-lssl`) is collected here and added to the FINAL link.
        let stub_link_flags : Array[String] = []
        let seen_pkg_id : Set[@model.PackageId] = Set([])
        // Run each module's `__moonbit_unstable_prebuild` script once (its side effects
        // happen now, before compiles); `link_configs[].link_flags` → per-package link.
        let prebuild_links = collect_prebuild_link_map(packages, order)
        for bt in order {
          if seen_pkg_id.contains(bt.pkg) {
            continue
          }
          seen_pkg_id.add(bt.pkg)
          let pkg = packages.get_package(bt.pkg)
          // Prebuild-reported link flags for this package (keyed by fqn).
          match prebuild_links.get(packages.get_fqn(bt.pkg)) {
            Some(words) =>
              for w in words {
                stub_link_flags.push(w)
              }
            None => ()
          }
          if pkg.native_stub_files.length() > 0 {
            let objs : Array[String] = []
            // translate-c the `moonbit.h` module for this package's `.zig` stubs: one
            // `TranslateC` action, shared by every `.zig` stub in the package (each may
            // `@import("moonbit")`). Only when the package both has a `.zig` stub to
            // consume it and opted in via `import-moonbit-h`.
            let zig_modules : Array[(String, String)] = []
            let mut has_zig_stub = false
            for s in pkg.native_stub_files {
              if s.has_suffix(".zig") {
                has_zig_stub = true
                break
              }
            }
            if has_zig_stub && pkg.needs_translate_moonbit_h {
              let zig = match nc.zig {
                Some(z) => z
                None =>
                  raise ZigToolchainMissing(
                    package_name=packages.get_fqn(bt.pkg),
                    stub=@core.MOONBIT_H,
                  )
              }
              let (tact, m) = translatec_action(
                cfg,
                nc,
                packages.get_fqn(bt.pkg),
                @core.MOONBIT_H,
                zig,
              )
              actions[tact.primary_output] = tact
              zig_modules.push(m)
            }
            for i, stub in pkg.native_stub_files {
              // Dispatch by stub language (`.zig` → zig, `.m`/`.mm` → clang, else
              // cc); the resulting `.o` is archived/linked identically in all cases.
              let o = stub_object_action(
                cfg,
                nc,
                packages.get_fqn(bt.pkg),
                i,
                stub,
                effective_native_link(pkg),
                zig_modules,
              )
              actions[o.primary_output] = o
              objs.push(o.primary_output)
            }
            let archive = archive_action(
              cfg,
              nc,
              packages.get_fqn(bt.pkg),
              objs,
            )
            actions[archive.primary_output] = archive
            stub_libs.push(archive.primary_output)
            for
              f in split_words(
                native_link_of(pkg).bind(fn(n) { n.stub_cc_link_flags }),
              ) {
              stub_link_flags.push(f)
            }
          }
        }
        let exe = make_exec_action(
          cfg,
          nc,
          main_fqn,
          link.primary_output,
          runtime_objects(cfg, nc),
          stub_libs,
          // cc / cc-flags / cc-link-flags come from the LINK ROOT's manifest.
          effective_native_link(packages.get_package(main_pkg_id)),
          packages.get_package(main_pkg_id).bin_name,
          // Module `link-flags` from the link root's owning module.
          packages.get_package(main_pkg_id).link_flags,
          stub_link_flags,
        )
        actions[exe.primary_output] = exe
        roots.push(exe.primary_output)
      }
    }
  }
  Plan::make(actions, roots, build_env(cfg))
}

///|
/// Lower a *library* rooted at `lib_fqn` into a [`Plan`]. Produces one
/// `build-package` action per package_name in `lib_fqn`'s dependency closure. The plan's
/// artifact is `lib_fqn`'s own `.core` (with its `.mi` byproduct alongside).
pub fn lib_plan(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  lib_fqn : String,
  cfg : BuildConfig,
) -> Plan raise BuildPlanError {
  root_plan(packages, deps_rel, [], [lib_fqn], cfg)
}

///|
/// Lower a `check` plan: type-check the root module's packages — plus the
/// dependency `.mi`s they require — with `moonc check`, producing one `.mi` per
/// package_name.
///
pub fn check_plan(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  cfg : BuildConfig,
  only? : Array[String]? = None,
) -> Plan raise BuildPlanError {
  let deps_rel = deps_rel.specialize(cfg.backend.name(), cfg.target_platform)
  // Roots: every package_name of the root module (the first one discovered, id 0),
  // restricted to `only` (the path-filter selection) when given. Dependency-module
  // packages are checked only as the closure pulls them in (to produce the `.mi`s
  // the root packages import), matching `moon check`'s scope.
  let roots : Array[@model.PackageId] = []
  for pkg_id in packages.root_package_ids() {
    let included = match only {
      Some(sel) => sel.contains(packages.get_fqn(pkg_id))
      None => true
    }
    if included {
      roots.push(pkg_id)
    }
  }
  guard roots.length() > 0 else {
    raise PackageNotFound(fqn="<root module has no packages>")
  }

  // Source packages plus their root-module test targets, matching rust moon's
  // `moon check` graph.
  let check_roots : Array[@pkg_solve.BuildTarget] = []
  for pkg_id in roots {
    check_roots.push(@pkg_solve.BuildTarget::primary(pkg_id))
  }
  for t in deps_rel.test_targets() {
    if roots.contains(t.pkg) {
      check_roots.push(t)
    }
  }
  let order = build_target_closure(deps_rel, check_roots)
  let check_cache = make_check_path_cache(packages, cfg)
  let actions : Map[String, @core.Action] = Map([])
  add_check_actions(packages, deps_rel, order, cfg, actions, check_cache)

  // Demand each selected source/test `.mi` directly — no aggregate.
  let root_mis : Array[String] = []
  for t in check_roots {
    root_mis.push(mi_path_t(cfg, packages.get_fqn(t.pkg), t.kind))
  }
  Plan::make(actions, root_mis, build_env(cfg))
}

///|
pub fn check_plan_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
  cfg : BuildConfig,
  only? : Array[String]? = None,
) -> Plan raise BuildPlanError {
  let deps = deps.specialize(cfg.backend.name(), cfg.target_platform)
  let roots : Array[@model.PackageId] = []
  for pkg_id in packages.root_package_ids() {
    let included = match only {
      Some(sel) => sel.contains(packages.get_fqn(pkg_id))
      None => true
    }
    if included {
      roots.push(pkg_id)
    }
  }
  guard roots.length() > 0 else {
    raise PackageNotFound(fqn="<root module has no packages>")
  }

  let order = build_packed_check_target_closure(
    deps,
    packages.package_count(),
    roots,
  )
  let check_cache = make_check_path_cache(packages, cfg)
  let actions : Map[String, @core.Action] = Map([])
  add_check_actions_packed(packages, deps, order, cfg, actions, check_cache)

  let root_mis : Array[String] = []
  for pkg_id in roots {
    root_mis.push(check_cache.mi(pkg_id))
  }
  Plan::make(actions, root_mis, build_env(cfg))
}

///|
/// Emit a compile action for every package_name in `order` — `build-package` when
/// `check` is false, `moonc check` when true — each preceded by any pre-build
/// codegen whose outputs feed it.
/// Reject the build if any package in the closure does not support the active
/// backend (`supported-targets`). Catches "build a native-only library for js"
/// up front with a clear error, instead of a confusing moonc failure deep in the
/// graph. (`check` is intentionally NOT gated — it is lenient across backends.)
fn gate_supported(
  packages : @model.BuildDiscovery,
  order : Array[@pkg_solve.BuildTarget],
  cfg : BuildConfig,
) -> Unit raise BuildPlanError {
  let target = cfg.backend.name()
  for bt in order {
    let pkg = packages.get_package(bt.pkg)
    if !pkg.supports(target) {
      raise UnsupportedTarget(package_name=packages.get_fqn(bt.pkg), target~)
    }
  }
}

///|
fn add_compile_actions(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  order : Array[@pkg_solve.BuildTarget],
  cfg : BuildConfig,
  actions : Map[String, @core.Action],
  check~ : Bool,
) -> Unit {
  // `$mooncake_bin` in a pre-build command resolves to the ROOT module's
  // `__moonbin__` launcher dir (where bin-deps install their executables). It is
  // a single project-level location, like rust moon's `mooncakes/__moonbin__`.
  let mooncake_bin = root_mooncake_bin(packages)
  for bt in order {
    let pkg_id = bt.pkg
    let pkg = packages.get_package(pkg_id)

    // A SUB-PACKAGE target: compile the declared file subset with its own imports
    // into `_sub` artifacts (`-pkg` keeps the parent name).
    if bt.kind is SubPackage {
      let act = sub_core_action(packages, deps_rel, pkg_id, cfg, check~)
      actions[act.primary_output] = act
      continue
    }

    let generated = emit_prebuild_actions(
      packages,
      pkg_id,
      actions,
      mooncake_bin~,
    )

    // A virtual package: generate its interface `.mi` from the hand-written
    // `.mbti` (`build-interface`). Consumers import this `.mi` like any other.
    if pkg.is_virtual() {
      let iface = build_interface_action(packages, deps_rel, pkg_id, cfg)
      actions[iface.primary_output] = iface
    }
    // An implementation package also needs the interface of the virtual it
    // implements — emit it here too, since that virtual may live in a module not
    // otherwise reached by `order` (idempotent: keyed by the `.mi` output path).
    match deps_rel.virt_impl_of(pkg_id) {
      Some(impl_id) => {
        let iface = build_interface_action(packages, deps_rel, impl_id, cfg)
        actions[iface.primary_output] = iface
      }
      None => ()
    }

    // Compile the concrete code, if any. In `check` mode skip virtual packages:
    // their interface action already produces the `.mi`, and `check` has no
    // separate `.core`, so a second action would double-produce that `.mi`.
    let emit = if check {
      pkg.has_implementation() && !pkg.is_virtual()
    } else {
      pkg.has_implementation()
    }
    if emit {
      let vimpl = compile_virtual_impl(packages, deps_rel, pkg_id, cfg)
      let act = if check {
        check_action(packages, deps_rel, pkg_id, cfg, generated, vimpl)
      } else {
        build_core_action(packages, deps_rel, pkg_id, cfg, generated, vimpl)
      }
      actions[act.primary_output] = act
    }
  }
}

///|
fn add_check_actions(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  order : Array[@pkg_solve.BuildTarget],
  cfg : BuildConfig,
  actions : Map[String, @core.Action],
  cache : CheckPathCache,
) -> Unit {
  let mooncake_bin = root_mooncake_bin(packages)
  for bt in order {
    let pkg_id = bt.pkg
    let pkg = packages.get_package(pkg_id)

    match bt.kind {
      WhiteboxTest | BlackboxTest | InlineTest => {
        let generated = emit_prebuild_actions(
          packages,
          pkg_id,
          actions,
          mooncake_bin~,
        )
        let act = check_test_action(packages, deps_rel, bt, cfg, generated)
        actions[act.primary_output] = act
        continue
      }
      _ => ()
    }

    if bt.kind is SubPackage {
      let act = sub_check_action_cached(packages, deps_rel, pkg_id, cfg, cache)
      actions[act.primary_output] = act
      continue
    }

    let generated = emit_prebuild_actions(
      packages,
      pkg_id,
      actions,
      mooncake_bin~,
    )

    if pkg.is_virtual() {
      let iface = build_interface_action(packages, deps_rel, pkg_id, cfg)
      actions[iface.primary_output] = iface
    }
    match deps_rel.virt_impl_of(pkg_id) {
      Some(impl_id) => {
        let iface = build_interface_action(packages, deps_rel, impl_id, cfg)
        actions[iface.primary_output] = iface
      }
      None => ()
    }

    if pkg.has_implementation() && !pkg.is_virtual() {
      let vimpl = compile_virtual_impl(packages, deps_rel, pkg_id, cfg)
      let act = check_action_cached(
        packages, deps_rel, pkg_id, cfg, cache, generated, vimpl,
      )
      actions[act.primary_output] = act
    }
  }
}

///|
fn add_check_actions_packed(
  packages : @model.BuildDiscovery,
  deps : @pkg_solve.PackedCheckDeps,
  order : Array[@pkg_solve.BuildTarget],
  cfg : BuildConfig,
  actions : Map[String, @core.Action],
  cache : CheckPathCache,
) -> Unit {
  let mooncake_bin = root_mooncake_bin(packages)
  for bt in order {
    let pkg_id = bt.pkg
    let pkg = packages.get_package(pkg_id)

    if bt.kind is SubPackage {
      let act = sub_check_action_packed(packages, deps, pkg_id, cfg, cache)
      actions[act.primary_output] = act
      continue
    }

    let generated = emit_prebuild_actions(
      packages,
      pkg_id,
      actions,
      mooncake_bin~,
    )

    if pkg.is_virtual() {
      let iface = build_interface_action_packed(
        packages, deps, pkg_id, cfg, cache,
      )
      actions[iface.primary_output] = iface
    }
    match deps.virt_impl_of(pkg_id) {
      Some(impl_id) => {
        let iface = build_interface_action_packed(
          packages, deps, impl_id, cfg, cache,
        )
        actions[iface.primary_output] = iface
      }
      None => ()
    }

    if pkg.has_implementation() && !pkg.is_virtual() {
      let vimpl = compile_virtual_impl_packed(packages, deps, pkg_id, cfg)
      let act = check_action_packed(
        packages, deps, pkg_id, cfg, cache, generated, vimpl,
      )
      actions[act.primary_output] = act
    }
  }
}
