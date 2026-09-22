// Lowers the test ("dev") build: each test target from the solver becomes a
// `generate-test-driver → build-package(test) → link-core(test) → cc(exe)`
// pipeline. Mirrors `moon test`'s shape (captured from `moon test --dry-run`):
//   - whitebox (`_wbtest.mbt`): compiled WITH the package's own sources into one
//     test core (`-whitebox-test`); same package_name name; deps = the package_name's imports.
//   - blackbox (`_test.mbt`): a separate package_name `<fqn>_blackbox_test` that imports
//     the package-under-test's `.mi` (`-blackbox-test`, `-doctest-only <src>`); links
//     the package_name's own `.core` alongside.
//   - inline (`internal`): inline `test { … }` blocks in the package's own sources,
//     compiled with the package (no `-whitebox`/`-blackbox` flag).
// Test exes run for their backend: native directly, js via `node`, wasm-gc/wasm via
// `moonrun` (see `cmd_testing.test_run_argv`).

///|
/// The test-driver entry points `link-core -test-mode` must export.
let test_exports : Array[String] = [
  "moonbit_test_driver_internal_execute", "moonbit_test_driver_finish",
]

///|
/// How to run one built test target: the runnable `artifact` (the native exe, or
/// the linked `.wasm`), the driver's `metadata` JSON (lists which tests exist, so
/// the runner can build the driver's `<file>:<start>-<end>` argv), and the source
/// `package` FQN (so a `--package` filter can select it — for all three test
/// kinds, including the renamed blackbox one).
pub(all) struct TestRun {
  artifact : String
  metadata : String
  package_fqn : String
  /// The module root (the `-workspace-path`). With workspace-path set, the driver
  /// reports test locations by WORKSPACE-relative filename (e.g. `src/lib/lib.mbt`),
  /// so `-u` resolves them against this to patch the right file.
  module_root : String
}

///|
/// Lower a `test` plan: build + link + (native) cc one executable per test target
/// in the root module's packages. The plan `root` is a phony aggregate over every
/// test exe (demanding it drives them all through the scheduler), like `check_plan`.
pub fn test_plan(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  cfg : BuildConfig,
  bench? : Bool = false,
) -> (Plan, Array[TestRun]) raise BuildPlanError {
  let deps_rel = deps_rel.specialize(cfg.backend.name(), cfg.target_platform)
  let actions : Map[String, @core.Action] = Map([])
  let targets = deps_rel.test_targets()

  // Build the Primary closure every test target leans on: the direct Primary deps
  // of each target (for blackbox this includes the package-under-test itself,
  // which the solver records as a Primary edge). One shared closure, deduped.
  let src_roots : Array[@pkg_solve.BuildTarget] = []
  for t in targets {
    for entry in deps_rel.deps_of_target(t) {
      let (dep, _) = entry
      src_roots.push(dep)
    }
    // A virtual override's implementation package is never imported, so the test
    // target's dep closure misses it — add each chosen impl explicitly so its
    // `.core` (compiled `-impl-virtual`) is built for the test link to substitute
    // in at the virtual's topological position.
    for _virtual_pid, impl_pkg_id in deps_rel.overrides_of(t.pkg) {
      src_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
    for _std_virtual_fqn, impl_pkg_id in deps_rel.std_overrides_of(t.pkg) {
      src_roots.push(@pkg_solve.BuildTarget::primary(impl_pkg_id))
    }
  }
  let order = build_target_closure(deps_rel, src_roots)
  add_compile_actions(packages, deps_rel, order, cfg, actions, check=false)

  // Per target: the driver + test compile + test link (+ native cc).
  let runs : Array[TestRun] = []
  for t in targets {
    match t.kind {
      @pkg_solve.WhiteboxTest
      | @pkg_solve.BlackboxTest
      | @pkg_solve.InlineTest =>
        runs.push(emit_test_target(packages, deps_rel, t, cfg, actions, bench~))
      _ => () // Primary/SubPackage: not test targets
    }
  }

  // Demand the test executables directly — one root per test target.
  (Plan::make(actions, runs.map(fn(r) { r.artifact }), build_env(cfg)), runs)
}

///|
/// Lower one whitebox/blackbox test target into its action pipeline, returning
/// the final artifact path (native exe, or the linked `.wasm`).
fn emit_test_target(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  t : @pkg_solve.BuildTarget,
  cfg : BuildConfig,
  actions : Map[String, @core.Action],
  bench? : Bool = false,
) -> TestRun raise BuildPlanError {
  let pkg = packages.get_package(t.pkg)
  let fqn = pkg.fqn

  // Per-kind shape: the tag for artifact names, the core driver kind, the test
  // package_name name, the build-package sources, the driver's scanned inputs, and the
  // blackbox `-doctest-only` source set.
  let generated = emit_prebuild_actions(
    packages,
    t.pkg,
    actions,
    mooncake_bin=root_mooncake_bin(packages),
  )
  let pkg_sources = compile_sources(pkg, generated, cfg) // the package_name's own (non-test) sources
  let (tag, driver_kind, test_pkg, build_sources, driver_inputs, doctest_only) = match
    t.kind {
    @pkg_solve.WhiteboxTest =>
      (
        "whitebox",
        @core.Whitebox,
        fqn,
        // whitebox compiles the package_name's sources + its wbtest files together
        [..pkg_sources, ..files_with_suffix(pkg, cfg, "_wbtest.mbt")],
        files_with_suffix(pkg, cfg, "_wbtest.mbt"),
        [],
      )
    @pkg_solve.InlineTest =>
      (
        "internal",
        @core.Internal,
        fqn,
        // internal compiles just the package_name's own sources (inline tests live in
        // them) + the driver; no `-whitebox-test` / `-blackbox-test` flag.
        pkg_sources,
        pkg_sources,
        [],
      )
    _ => {
      // blackbox compiles its `_test.mbt` files AND `.mbt.md` markdown tests (+
      // driver); the package_name's own sources come in as doctests (`--doctest-only`)
      // and as the linked `.core`.
      let bb_sources = [
        ..files_with_suffix(pkg, cfg, "_test.mbt"),
        ..pkg.mbt_md_files,
      ]
      (
        "blackbox",
        @core.Blackbox,
        fqn + "_blackbox_test",
        bb_sources,
        bb_sources,
        pkg_sources,
      )
    }
  }
  // 1. generate-test-driver: emits the driver `.mbt` (+ metadata json byproduct).
  // The basename MUST start with `__generated_driver_` so moonc excludes it from
  // coverage instrumentation (else `.trace.source` references the driver and
  // `moon_cove_report` fails to read it). Package-scoped layout keeps names local
  // to the package directory, matching rust moon's target layout.
  let driver = @pathx.join([
    package_dir(cfg, fqn),
    "__generated_driver_for_" + tag + "_test.mbt",
  ])
  let metadata = @pathx.join([
    package_dir(cfg, fqn),
    "_" + tag + "_test_info.json",
  ])
  actions[driver] = {
    primary_output: driver,
    outputs: [driver, metadata],
    inputs: [..driver_inputs, ..doctest_only],
    spec: @core.GenerateTestDriver(
      kind=driver_kind,
      test_sources=driver_inputs,
      doctest_only~,
      metadata~,
      pkg_name=fqn, // the driver names the ORIGINAL package_name, even for blackbox
      coverage=cfg.coverage,
      bench~,
      max_concurrent_tests=pkg.max_concurrent_tests,
    ),
  }

  // 2. build-package (test): sources + driver → the test `.core` (no `.mi`).
  let test_core = test_path(cfg, fqn, "." + tag + "_test.core")
  let sources = [..build_sources, driver]
  let dep_imports : Array[@core.MiDep] = []
  let dep_cores : Array[String] = []
  for entry in deps_rel.deps_of_target(t) {
    let (dep, edge) = entry
    let dpkg = packages.get_package(dep.pkg)
    let dfqn = dpkg.fqn
    dep_imports.push({ mi: mi_path(cfg, dfqn), import_alias: edge.short_alias })
    // A virtual dep contributes only its interface `.mi` (from `build-interface`) —
    // it has no `.core` of its own (the implementation's core is linked later via
    // override substitution). Depend on the `.mi` so the interface is built first.
    if dpkg.is_virtual() {
      dep_cores.push(mi_path(cfg, dfqn))
    } else {
      dep_cores.push(core_path(cfg, dfqn))
    }
  }
  // `doctest_only` files are read by `-doctest-only` (not positional sources), so
  // they must be listed as inputs or a doctest edit won't invalidate the cache.
  let build_inputs = [..sources, ..dep_cores, ..doctest_only]
  actions[test_core] = {
    primary_output: test_core,
    outputs: [test_core],
    inputs: build_inputs,
    spec: @core.Compile(
      check=false,
      sources~,
      fqn=test_pkg,
      is_main=true,
      std_bundle=cfg.std.map(fn(s) { s.bundle }),
      deps=dep_imports,
      std_imports=collect_std_imports(packages, pkg.imports, cfg),
      pkg_root=pkg.root_path,
      test_kind=Some(driver_kind),
      doctest_only~,
      workspace=Some(pkg.module_root),
      all_pkgs=Some(all_pkgs_path(cfg)),
      coverage=cfg.coverage,
      value_tracing=cfg.value_tracing,
      virtual_impl=None,
      no_mi=true,
      warn_list=effective_warn_list(pkg, cfg),
      alert_list=pkg.alert_list,
      compile_flags=[..pkg.compile_flags, ..platform_cfg(cfg)],
    ),
  }

  // 3. link-core (test): the transitive Primary closure of the target's deps +
  // the test core. (For blackbox the closure includes the package_name's own `.core`;
  // for whitebox it does not — its sources live inside the test core.)
  // The package-under-test's virtual override selections (virtual -> impl); the
  // link order substitutes each overridden virtual with its implementation `.core`.
  let overrides = deps_rel.overrides_of(t.pkg)
  let std_overrides = deps_rel.std_overrides_of(t.pkg)
  let std_abort_overridden = std_overrides.contains("moonbitlang/core/abort")
  let link_roots : Array[@pkg_solve.BuildTarget] = []
  for entry in deps_rel.deps_of_target(t) {
    let (dep, _) = entry
    link_roots.push(dep)
  }
  let link_order = link_core_order_multi(deps_rel, link_roots, overrides)
  let cores : Array[String] = []
  let link_inputs : Array[String] = []
  let pkg_src_pairs : Array[(String, String)] = []
  match cfg.std {
    Some(std) => {
      if !std_abort_overridden {
        link_inputs.push(std.bundle + "/abort/abort.core")
      }
      link_inputs.push(std.bundle + "/core.core")
      if std_abort_overridden {
        cores.push(std.bundle + "/core.core")
      }
    }
    None => ()
  }
  for bt in link_order {
    let p = packages.get_package(bt.pkg)
    // A virtual package that survived substitution (no override) must carry its own
    // default `.core`; a no-default virtual with no override has nothing to link.
    if bt.kind is Primary && p.is_virtual() && !p.virtual_has_default {
      raise NoImplementation(virtual_pkg=p.fqn)
    }
    let c = core_path_t(cfg, p.fqn, bt.kind)
    cores.push(c)
    link_inputs.push(c)
    pkg_src_pairs.push((p.fqn, p.root_path))
  }
  for _std_virtual_fqn, impl_pkg_id in std_overrides {
    let p = packages.get_package(impl_pkg_id)
    let c = core_path(cfg, p.fqn)
    cores.push(c)
    link_inputs.push(c)
    pkg_src_pairs.push((p.fqn, p.root_path))
  }
  cores.push(test_core)
  link_inputs.push(test_core)
  pkg_src_pairs.push((test_pkg, pkg.root_path))
  let link_out = test_path(cfg, fqn, "." + tag + "_test" + link_ext(cfg))
  // `link-core` byproducts that must be CACHED alongside the test binary, else a
  // warm-cache HIT (fresh `_build`) leaves them missing:
  //   • `.trace.source` (coverage on any backend) — the coverage source map
  //     `moon_cove_report` reads; without it `moon coverage` errors "No coverage
  //     source data found" even though the run wrote `moonbit_coverage_*.txt`.
  //   • `<out>.map` (debug on wasm/js) — the JS/wasm source map.
  let link_outputs : Array[String] = [link_out]
  if cfg.coverage {
    link_outputs.push(test_path(cfg, fqn, "." + tag + "_test.trace.source"))
  }
  if emits_source_map(cfg) {
    link_outputs.push(link_out + ".map")
  }
  actions[link_out] = {
    primary_output: link_out,
    outputs: link_outputs,
    inputs: link_inputs,
    spec: @core.LinkCore(
      std_bundle=if std_abort_overridden {
        None
      } else {
        cfg.std.map(fn(s) { s.bundle })
      },
      cores~,
      main=test_pkg,
      pkg_config=Some(pkg.root_path + "/moon.pkg.json"),
      pkg_sources=pkg_src_pairs,
      std_core_root=cfg.std.map(fn(s) { s.core_root }),
      test_mode=true,
      exported_functions=test_exports,
      // The js test driver must be loadable by `node` directly (CommonJS): test-mode
      // link-core exports the driver entry points, and moonc's default JS format is
      // now ESM (`export {…}`), which node rejects as a `.js` CJS script — official
      // moon emits CJS test drivers for the same reason.
      js_format=match cfg.backend {
        Js => Some("cjs")
        _ => None
      },
      wasm_opts=None,
      link_flags=pkg.link_flags,
      // "New native": a test exe links the same `.o` lowering as a normal build.
      native_target=cfg.native_target,
      output_wat=cfg.output_wat,
    ),
  }

  // 4. native: cc the emitted `.c` + runtime + toolchain objects into the exe.
  let artifact = match cfg.backend.native_config() {
    None => link_out // wasm-gc: the linked artifact IS the test executable
    Some(nc) => {
      let runtime_objs : Array[String] = []
      for act in runtime_actions(cfg, nc) {
        actions[act.primary_output] = act
        runtime_objs.push(act.primary_output)
      }
      // A test exe DOES link native stubs: every package in its link closure (the
      // package-under-test + its transitive Primary deps) that has `native_stub_files`
      // — e.g. a whitebox test of a package with `extern "c"` needs that package's
      // `.o` for the native helper symbols, else the link fails with
      // "undefined reference".
      let (stub_libs, stub_link_flags) = collect_test_stubs(
        packages, deps_rel, t, cfg, nc, actions,
      )
      let exe = make_exec_action(
        cfg,
        nc,
        fqn,
        link_out,
        runtime_objs,
        stub_libs,
        effective_native_link(pkg),
        None,
        pkg.link_flags,
        stub_link_flags,
        out_override=test_path(cfg, fqn, "." + tag + "_test.exe"),
      )
      actions[exe.primary_output] = exe
      exe.primary_output
    }
  }
  { artifact, metadata, package_fqn: fqn, module_root: pkg.module_root }
}

///|
/// Compile + collect the native stubs a native test exe must link: every package in the
/// test's link closure (the package-under-test `t.pkg` + its transitive Primary deps)
/// that owns `native_stub_files`. Mirrors the build path's stub loop (`build_plan.mbt`):
/// per stub-owning package, optionally translate-c `moonbit.h` for its `.zig` stubs,
/// `stub_object_action` each stub → `archive_action` → one `lib<pkg>.a`, plus that
/// package's `stub-cc-link-flags`. Returns
/// (stub archive paths, extra stub link flags). Actions dedup by output path, so a
/// stub shared across test targets is compiled once.
fn collect_test_stubs(
  packages : @model.BuildDiscovery,
  deps_rel : @pkg_solve.DepRelationship,
  t : @pkg_solve.BuildTarget,
  cfg : BuildConfig,
  nc : NativeToolchain,
  actions : Map[String, @core.Action],
) -> (Array[String], Array[String]) raise BuildPlanError {
  // Roots: the package-under-test itself (whitebox compiles its sources in) + the
  // test target's direct deps; the closure pulls in everything transitively linked.
  let roots : Array[@pkg_solve.BuildTarget] = [
    @pkg_solve.BuildTarget::primary(t.pkg),
  ]
  for entry in deps_rel.deps_of_target(t) {
    roots.push(entry.0)
  }
  let stub_libs : Array[String] = []
  let stub_link_flags : Array[String] = []
  let closure = build_target_closure(deps_rel, roots)
  // Run each module's `__moonbit_unstable_prebuild` once for the test closure too
  // (side effects + `link_configs` link flags), like the main build path.
  let prebuild_links = collect_prebuild_link_map(packages, closure)
  let seen : Set[@model.PackageId] = Set([])
  for bt in closure {
    if seen.contains(bt.pkg) {
      continue
    }
    seen.add(bt.pkg)
    let pkg = packages.get_package(bt.pkg)
    // Per-package native-link contributions for the test closure mirror the main
    // build path: prebuild `link_configs` join the test exe's link.
    match prebuild_links.get(pkg.fqn) {
      Some(words) =>
        for w in words {
          stub_link_flags.push(w)
        }
      None => ()
    }
    if pkg.native_stub_files.length() > 0 {
      let objs : Array[String] = []
      // translate-c the `moonbit.h` module for this package's `.zig` stubs, exactly
      // as the main build does (`build_plan.mbt`): one shared `TranslateC` action,
      // only when the package has a `.zig` stub AND opted in via `import-moonbit-h`.
      // Without this a test exe linking such a stub couldn't resolve `@import("moonbit")`.
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
              package_name=pkg.fqn,
              stub=@core.MOONBIT_H,
            )
        }
        let (tact, m) = translatec_action(
          cfg,
          nc,
          pkg.fqn,
          @core.MOONBIT_H,
          zig,
        )
        actions[tact.primary_output] = tact
        zig_modules.push(m)
      }
      for i, stub in pkg.native_stub_files {
        // Dispatch by stub language (`.zig`/`.m`/`.c`), like the main build.
        let o = stub_object_action(
          cfg,
          nc,
          pkg.fqn,
          i,
          stub,
          effective_native_link(pkg),
          zig_modules,
        )
        actions[o.primary_output] = o
        objs.push(o.primary_output)
      }
      let archive = archive_action(cfg, nc, pkg.fqn, objs)
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
  (stub_libs, stub_link_flags)
}

///|
/// A test artifact path: `<package-dir>/<artifact><suffix>`.
fn test_path(cfg : BuildConfig, fqn : String, suffix : String) -> String {
  artifact_stem(cfg, fqn) + suffix
}

///|
/// The package_name's source files ending in `suffix` (e.g. `_wbtest.mbt`), with
/// target-excluded files dropped, sorted as discovered.
fn files_with_suffix(
  pkg : @model.BuildPackage,
  cfg : BuildConfig,
  suffix : String,
) -> Array[String] {
  let out : Array[String] = []
  for f in pkg.source_files {
    if f.has_suffix(suffix) && !target_excludes(pkg, f, cfg) {
      out.push(f)
    }
  }
  out
}
