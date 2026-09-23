// The plan entry points: lower a solved dependency graph into a `Plan` (a
// map of artifact path -> `@core.Action` + the root artifact). Each flavor starts from its target(s) and pulls in exactly the dependency
// closure. The per-stage machinery lives alongside: traverse / sources /
// prebuild / actions(_native) / layout.

///|
/// Lower one executable and its dependency closure into an artifact plan.
pub fn build_plan(
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  main_fqn : String,
  cfg : BuildConfig,
) -> Plan raise BuildPlanError {
  // Select backend-specific imports before traversing dependencies.
  let deps_rel = deps_rel.specialize(cfg.backend.name())
  let main_pkg_id = match packages.get_package_id_by_name(main_fqn) {
    Some(id) => id
    None => raise PackageNotFound(fqn=main_fqn)
  }
  let overrides = deps_rel.overrides_of(main_pkg_id)
  let std_overrides = deps_rel.std_overrides_of(main_pkg_id)
  let all_roots = [@pkg_solve.BuildTarget::primary(main_pkg_id)]
  for _virtual_pid, impl_pkg_id in overrides {
    all_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
  }
  for _std_virtual_fqn, impl_pkg_id in std_overrides {
    all_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
  }
  let all_order = build_target_closure(deps_rel, all_roots) // deps before dependents
  gate_supported(packages, all_order, cfg)
  let actions : Map[String, @core.Action] = Map([])
  add_compile_actions(packages, deps_rel, all_order, cfg, actions)
  let roots : Array[String] = []
  match cfg.backend.native_config() {
    Some(nc) =>
      for act in runtime_actions(cfg, nc) {
        actions[act.primary_output] = act
      }
    None => ()
  }

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
      let prebuild_links = collect_prebuild_link_map(packages, all_order)
      for bt in all_order {
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
          for stub in pkg.native_stub_files {
            // Dispatch by stub language (`.zig` → zig, `.m`/`.mm` → clang, else
            // cc); the resulting `.o` is archived/linked identically in all cases.
            let o = stub_object_action(
              cfg,
              nc,
              packages.get_fqn(bt.pkg),
              stub,
              effective_native_link(pkg),
              zig_modules,
            )
            actions[o.primary_output] = o
            objs.push(o.primary_output)
          }
          let archive = archive_action(cfg, nc, packages.get_fqn(bt.pkg), objs)
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
  Plan::make(actions, roots, build_env(cfg))
}

///|
/// Reject the build if any package in the closure does not support the active
/// backend (`supported-targets`). Catches "build a native-only library for js"
/// up front with a clear error, instead of a confusing moonc failure deep in the
/// graph.
fn gate_supported(
  packages : @model.PackageTable,
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
  packages : @model.PackageTable,
  deps_rel : @pkg_solve.DepRelationship,
  order : Array[@pkg_solve.BuildTarget],
  cfg : BuildConfig,
  actions : Map[String, @core.Action],
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
      let act = sub_core_action(packages, deps_rel, pkg_id, cfg)
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

    if pkg.has_implementation() {
      let vimpl = compile_virtual_impl(packages, deps_rel, pkg_id, cfg)
      let act = build_core_action(
        packages, deps_rel, pkg_id, cfg, generated, vimpl,
      )
      actions[act.primary_output] = act
    }
  }
}
