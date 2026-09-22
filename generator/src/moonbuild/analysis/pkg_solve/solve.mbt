// Solves the package_name dependency graph from discovered packages.
//
// For each package_name we resolve every import string to a package_name id, check the
// internal-visibility rule and import_alias uniqueness, and add a dependent->dependency
// edge. Finally we reject any cycle in the resulting graph.

///|
fn timing_enabled() -> Bool {
  @os.getenv("MYMOON_TIMING") is Some("1")
}

///|
fn timing_ms(start : Int64) -> Int64 {
  (@os.now_ns() - start) / 1_000_000L
}

///|
fn timing_log(label : String, start : Int64) -> Unit {
  let ms = timing_ms(start)
  if timing_enabled() && ms > 0 {
    @os.eprintln("timing \{label}: \{ms}ms")
  }
}

///|
/// Solve and validate the dependency relationship between all discovered
/// packages.
pub fn solve(
  packages : @model.BuildDiscovery,
) -> DepRelationship raise SolveError {
  solve_inner(packages, include_tests=true)
}

///|
/// Solve only the package build graph. `moon check` / `moon build` never consume
/// test targets, so skipping them avoids constructing root-module
/// Whitebox/Blackbox/Inline nodes on the hot path. `moon test` / `moon bench`
/// still use [`solve`].
pub fn solve_without_tests(
  packages : @model.BuildDiscovery,
) -> DepRelationship raise SolveError {
  solve_inner(packages, include_tests=false)
}

///|
fn solve_inner(
  packages : @model.BuildDiscovery,
  include_tests~ : Bool,
) -> DepRelationship raise SolveError {
  let res = DepRelationship::new()
  let n = packages.package_count()
  // Pass 0: resolve every package's `implement` field into `virt_impl`. Split
  // out because the main pass (import rejection + override resolution) must see
  // which packages implement which virtual BEFORE it runs.
  let t_virtual_impl = @os.now_ns()
  for i in 0..<n {
    let pkg_id = @model.PackageId(i)
    solve_virtual_impl(res, packages, pkg_id)
  }
  timing_log("solve.virtual_impl", t_virtual_impl)
  let t_packages = @os.now_ns()
  for i in 0..<n {
    let pkg_id = @model.PackageId(i)
    solve_one_package(res, packages, pkg_id, include_tests~)
  }
  timing_log("solve.packages", t_packages)
  let t_cycles = @os.now_ns()
  check_no_cycles(res, n)
  timing_log("solve.cycles", t_cycles)
  res
}

///|
/// Resolve one package's `implement = <virtual>` field: look the target up, check
/// it is actually a virtual package, and record `impl -> virtual` in `virt_impl`.
fn is_std_virtual_package(fqn : String) -> Bool {
  fqn == "moonbitlang/core/abort"
}

///|
fn solve_virtual_impl(
  res : DepRelationship,
  packages : @model.BuildDiscovery,
  pkg_id : @model.PackageId,
) -> Unit raise SolveError {
  let pkg = packages.get_package(pkg_id)
  let pkg_fqn = packages.get_fqn(pkg_id)
  match pkg.implement {
    None => ()
    Some(target_path) => {
      let target_pkg_id = match packages.get_package_id_by_name(target_path) {
        Some(id) => id
        None => {
          if is_std_virtual_package(target_path) {
            res.std_virt_impl[pkg_id] = target_path
            return
          }
          raise ImportNotFound(import_path=target_path, package_name=pkg_fqn)
        }
      }
      if !packages.get_package(target_pkg_id).is_virtual() {
        raise ImplementTargetNotVirtual(
          package_name=pkg_fqn,
          target=target_path,
        )
      }
      res.virt_impl[pkg_id] = target_pkg_id
    }
  }
}

///|
/// Resolve and record the dependency edges contributed by one package_name's imports.
fn solve_one_package(
  res : DepRelationship,
  packages : @model.BuildDiscovery,
  pkg_id : @model.PackageId,
  include_tests~ : Bool,
) -> Unit raise SolveError {
  let pkg = packages.get_package(pkg_id)
  let src = BuildTarget::primary(pkg_id)
  // The Primary target's resolved dependency edges, reused by the package_name's test
  // targets (a `_wbtest`/`_test` file shares the package_name's import list).
  let dep_edges = add_import_edges(
    res,
    packages,
    src,
    pkg_id,
    pkg,
    pkg.imports,
    via="import",
  )

  // Conditional imports (`import {} for "<x>"`): add each set as edges tagged with
  // its condition (backend OR platform), so `DepRelationship::specialize` keeps only
  // the matching ones for a build — keeping a leaf's other-backend/other-OS imports
  // out of THIS build's closure (so they don't poison its supported-targets).
  for section, specs in pkg.cond_imports {
    add_import_edges(
      res,
      packages,
      src,
      pkg_id,
      pkg,
      specs,
      via="import",
      cond=Some(classify_dep_cond(section)),
    )
    |> ignore
  }

  // A SUB-PACKAGE is a separate build target: a file subset compiled with its OWN
  // (smaller) import list. Register the target and resolve its imports as edges
  // from it. Used to break dependency cycles — the sub-package target carries
  // fewer deps than the package's Primary target, so a consumer that needs only the
  // subset (importing it via `sub-package: true`) avoids the heavier closure.
  match pkg.sub_package {
    Some(sub) => {
      let sub_target = BuildTarget::{ pkg: pkg_id, kind: SubPackage }
      res.add_node(sub_target)
      add_import_edges(
        res,
        packages,
        sub_target,
        pkg_id,
        pkg,
        sub.imports,
        via="import",
      )
      |> ignore
    }
    None => ()
  }

  // Resolve `overrides`: each entry names an implementation package; record the
  // consumer's (virtual -> chosen impl) selection. Validated against `virt_impl`
  // (resolved in pass 0): the named package must actually implement a virtual one,
  // and no two overrides may target the same virtual package.
  if !pkg.overrides.is_empty() {
    let sel : Map[@model.PackageId, @model.PackageId] = Map([])
    let std_sel : Map[String, @model.PackageId] = Map([])
    for over_path in pkg.overrides {
      let over_pkg_id = match packages.get_package_id_by_name(over_path) {
        Some(id) => id
        None =>
          raise ImportNotFound(
            import_path=over_path,
            package_name=packages.get_fqn(pkg_id),
          )
      }
      match res.virt_impl.get(over_pkg_id) {
        Some(virtual_pkg_id) =>
          match sel.get(virtual_pkg_id) {
            Some(existing) =>
              raise VirtualOverrideConflict(
                package_name=packages.get_fqn(pkg_id),
                virtual_pkg=packages.get_fqn(virtual_pkg_id),
                first=packages.get_fqn(existing),
                second=over_path,
              )
            None => sel[virtual_pkg_id] = over_pkg_id
          }
        None =>
          match res.std_virt_impl.get(over_pkg_id) {
            Some(std_virtual_fqn) =>
              match std_sel.get(std_virtual_fqn) {
                Some(existing) =>
                  raise VirtualOverrideConflict(
                    package_name=packages.get_fqn(pkg_id),
                    virtual_pkg=std_virtual_fqn,
                    first=packages.get_fqn(existing),
                    second=over_path,
                  )
                None => std_sel[std_virtual_fqn] = over_pkg_id
              }
            None =>
              raise OverrideNotImplementor(
                package_name=packages.get_fqn(pkg_id),
                override_=over_path,
              )
          }
      }
    }
    if !sel.is_empty() {
      res.virtual_users[pkg_id] = sel
    }
    if !std_sel.is_empty() {
      res.std_virtual_users[pkg_id] = std_sel
    }
  }

  // Test targets: a package_name's test files form separate build targets. Whitebox
  // (`_wbtest.mbt`) compiles together WITH the package_name's own sources, so it shares
  // exactly the package_name's import deps. Blackbox (`_test.mbt`) is a separate package_name
  // that, on top of those imports, depends on the package-under-test's Primary
  // (which it imports through the public API). Both are graph leaves — nothing
  // depends on a test target — so they never enter cycle detection or the Primary
  // view, only a test build pulls them in.
  //
  // Only the ROOT module's packages get test targets — `moon test` tests YOUR
  // code, not your dependencies'. (Deps still contribute their Primary targets
  // above; we just never build/run a dependency's `_wbtest`/`_test`/doctests.)
  let @model.ModuleId(mid) = pkg.module_id
  // Lint: a MAIN package is an executable, not an importable library, so blackbox
  // test inputs (`_test.mbt` / `.mbt.md`, which compile against it as an external
  // importer would) don't belong on it. Whitebox/inline tests are fine. Matches
  // upstream's "Main package … uses blackbox-only test inputs".
  if mid == 0 && pkg.is_main {
    let kinds : Array[String] = []
    if pkg.has_blackbox_tests() {
      kinds.push("`_test.mbt` files")
    }
    if !pkg.mbt_md_files.is_empty() {
      kinds.push("`.mbt.md` files")
    }
    if !kinds.is_empty() {
      @os.eprintln(
        "warning: Main package `\{pkg.fqn}` (package directory \"\{pkg.root_path}\") uses blackbox-only test inputs (\{kinds.join(", ")})",
      )
    }
  }
  // Each test target replays the Primary target's resolved dep edges (a test file
  // shares the package's import list).
  if !include_tests {
    return
  }
  fn replay_deps(t : BuildTarget) -> Unit {
    for d in dep_edges {
      let (dep_src, edge) = d
      res.add_edge(t, dep_src, edge)
    }
  }

  guard mid == 0 else { return }
  if pkg.has_whitebox_tests() {
    let wb = BuildTarget::{ pkg: pkg_id, kind: WhiteboxTest }
    res.add_node(wb)
    replay_deps(wb)
    // Whitebox tests may additionally import packages the package itself doesn't
    // (`import {} for "wbtest"` / `wbtest-import`).
    add_import_edges(
      res,
      packages,
      wb,
      pkg_id,
      pkg,
      pkg.wbtest_imports,
      via="wbtest-import",
    )
    |> ignore
  }
  // Inline (`internal`) tests compile WITH the package_name's own sources too, so they
  // share the same import deps as the Primary target. Discovery no longer scans
  // source content for inline tests; the generated driver/compiler decide whether
  // any tests exist.
  if !pkg.source_files.is_empty() {
    let it = BuildTarget::{ pkg: pkg_id, kind: InlineTest }
    res.add_node(it)
    replay_deps(it)
  }
  // Blackbox covers `_test.mbt` files, doctests (via `--doctest-only`), AND
  // `.mbt.md` markdown tests (compiled as blackbox sources) — any of them needs
  // the blackbox target. It additionally depends on the package-under-test's
  // Primary (imported via the public API), added first to preserve edge order.
  if pkg.has_blackbox_tests() ||
    !pkg.source_files.is_empty() ||
    !pkg.mbt_md_files.is_empty() {
    let bb = BuildTarget::{ pkg: pkg_id, kind: BlackboxTest }
    res.add_node(bb)
    res.add_edge(bb, src, {
      short_alias: packages.get_short_alias(pkg_id),
      kind: Primary,
      cond: None,
    })
    replay_deps(bb)
    // Blackbox tests may additionally import packages the package itself doesn't
    // (`import {} for "test"` / `test-import`).
    add_import_edges(
      res,
      packages,
      bb,
      pkg_id,
      pkg,
      pkg.test_imports,
      via="test-import",
    )
    |> ignore
  }
}

///|
/// Resolve an import list into dependency edges FROM the given `from` build target
/// (the `Primary` target, or a `SubPackage` target with its own import list). Each
/// edge points to the dependency's `Primary` target — or its `SubPackage` target
/// when the import carries `sub-package: true`. Returns the resolved edges (the
/// `Primary` target's are replayed onto the package's test targets). Validates
/// stdlib-skip, virtual-impl-not-importable, internal visibility, and per-list
/// alias uniqueness.
fn add_import_edges(
  res : DepRelationship,
  packages : @model.BuildDiscovery,
  from : BuildTarget,
  importer_id : @model.PackageId,
  importer : @model.BuildPackage,
  specs : Array[@config.ImportSpec],
  via~ : String,
  cond? : DepCond? = None,
) -> Array[(BuildTarget, DepEdge)] raise SolveError {
  let seen_alias : Map[String, String] = Map([])
  let edges : Array[(BuildTarget, DepEdge)] = []
  for spec in specs {
    let import_path = spec.path
    let maybe_dep_pkg_id = packages.get_package_id_by_name(import_path)
    // Standard-library packages (`moonbitlang/core/*`) are PROVIDED by the
    // toolchain bundle, not discovered/built here, so they form no local edge;
    // build_plan wires their `.mi` straight from the bundle. Skip them — UNLESS
    // the import was locally discovered, i.e. the project IS `moonbitlang/core`
    // (`moon bundle` building the std from source): local wins, and the import
    // becomes an ordinary project edge.
    if is_stdlib_import(import_path) && maybe_dep_pkg_id is None {
      continue
    }
    let dep_pkg_id = match maybe_dep_pkg_id {
      Some(id) => id
      None =>
        raise ImportNotFound(
          import_path~,
          package_name=packages.get_fqn(importer_id),
        )
    }
    let dep = packages.get_package(dep_pkg_id)

    // Lint: importing a MAIN package (an executable entry point, not a library)
    // is almost always a mistake — a main package exports no usable API. Warn for
    // the root module's own imports (not dependencies'). Matches upstream's
    // "depends on main package … via `import`/`wbtest-import`/`test-import`".
    let @model.ModuleId(im) = importer.module_id
    if dep.is_main && im == 0 {
      @os.eprintln(
        "warning: package `\{packages.get_fqn(importer_id)}` (package directory \"\{importer.root_path}\") depends on main package `\{packages.get_fqn(dep_pkg_id)}` via `\{via}`",
      )
    }

    // A virtual-implementation package is never imported directly: consumers
    // import the VIRTUAL interface and pick the impl via `overrides`.
    if dep.is_virtual_impl() {
      raise CannotImportVirtualImplementation(
        importer=packages.get_fqn(importer_id),
        dependency=packages.get_fqn(dep_pkg_id),
      )
    }

    // Internal-visibility rule.
    if !packages.can_import(importer_id, dep_pkg_id) {
      raise InternalImportForbidden(
        importer=packages.get_fqn(importer_id),
        dependency=packages.get_fqn(dep_pkg_id),
      )
    }

    // Use the explicit import_alias if declared, else the dependency's short name.
    let import_alias = match spec.import_alias {
      Some(a) => a
      None => packages.get_short_alias(dep_pkg_id)
    }
    match seen_alias.get(import_alias) {
      // Same alias already seen. If it resolves to the SAME path, this is a
      // harmless duplicate import (some upstream `moon.pkg`s list a path twice,
      // e.g. `moonbitlang/async/fs`) — dedupe it, as moonc does. Only a DIFFERENT
      // path collapsing onto the alias is a genuine conflict.
      Some(first) =>
        if first != import_path {
          raise ConflictingImportAlias(
            import_alias~,
            package_name=packages.get_fqn(importer_id),
            first~,
            second=import_path,
          )
        } else {
          continue
        }
      None => seen_alias[import_alias] = import_path
    }
    // `sub-package: true` → depend on the dependency's SUB-PACKAGE target (its
    // `_sub.mi`), not its `Primary` interface.
    let kind : TargetKind = if spec.sub_package { SubPackage } else { Primary }
    let to = BuildTarget::{ pkg: dep_pkg_id, kind }
    let edge : DepEdge = { short_alias: import_alias, kind, cond }
    res.add_edge(from, to, edge)
    edges.push((to, edge))
  }
  add_reexport_edges(res, packages, from, seen_alias, edges, cond~)
  edges
}

///|
/// Classify an `import {} for "<section>"` section string into its [`DepCond`]: a
/// known backend name → [`Backend`], otherwise a platform spec → [`Platform`]. The
/// two name-spaces are disjoint and the manifest decoder already validated the
/// section, so the fall-through to `Platform` is safe.
fn classify_dep_cond(section : String) -> DepCond {
  if section is ("native" | "wasm-gc" | "wasm" | "js" | "llvm") {
    Backend(section)
  } else {
    Platform(section)
  }
}

///|
/// Propagate `pub using` re-exports. If `from` imports package P and P re-exports
/// package Q (`pub using @q {…}` in P's source), then `from`'s compile needs Q's
/// `.mi` even though `from` never imports Q directly — a consumer referring to
/// `@p.SomeReExportedType` makes moonc look up that type's home package (Q) and
/// demand its interface. We add an implicit edge `from -> Q.Primary`, transitively
/// (Q may itself re-export), deduped against what `from` already imports.
///
/// The edge's alias is cosmetic: moonc resolves a re-exported type by its home
/// package NAME, not by the alias under which Q happens to be loaded. So a
/// synthetic, collision-free alias is fine — and necessary, since Q's natural
/// short alias may already be taken by a direct import.
fn add_reexport_edges(
  res : DepRelationship,
  packages : @model.BuildDiscovery,
  from : BuildTarget,
  seen_alias : Map[String, String],
  edges : Array[(BuildTarget, DepEdge)],
  cond? : DepCond? = None,
) -> Unit {
  // Packages already wired to `from` (directly or via an earlier re-export hop):
  // never add a second `.mi` for the same package.
  let seen_pkg_id : Set[@model.PackageId] = Set([])
  for entry in edges {
    seen_pkg_id.add(entry.0.pkg)
  }
  // Aliases already on the compile line, so a synthetic alias stays unique.
  let used_alias : Set[String] = Set([])
  for a, _ in seen_alias {
    used_alias.add(a)
  }
  // Seed the worklist with the re-exports of every package `from` directly imports.
  let work : Array[String] = []
  for entry in edges {
    for path in packages.get_package(entry.0.pkg).reexports {
      work.push(path)
    }
  }
  let mut wi = 0
  while wi < work.length() {
    let path = work[wi]
    wi = wi + 1
    // A re-exported stdlib package is provided by the bundle — no extra edge.
    if is_stdlib_import(path) {
      continue
    }
    let pkg_id = match packages.get_package_id_by_name(path) {
      Some(id) => id
      None => continue
    }
    if seen_pkg_id.contains(pkg_id) {
      continue
    }
    seen_pkg_id.add(pkg_id)
    let dep = packages.get_package(pkg_id)
    let alias_name = unique_alias(packages.get_short_alias(pkg_id), used_alias)
    used_alias.add(alias_name)
    let to = BuildTarget::{ pkg: pkg_id, kind: Primary }
    let edge : DepEdge = { short_alias: alias_name, kind: Primary, cond }
    res.add_edge(from, to, edge)
    edges.push((to, edge))
    // Transitive: Q may itself re-export further packages.
    for next in dep.reexports {
      work.push(next)
    }
  }
}

///|
/// `base` if free, else `base2`, `base3`, … — the first not already in `used`.
fn unique_alias(base : String, used : Set[String]) -> String {
  if !used.contains(base) {
    return base
  }
  let mut i = 2
  while used.contains(base + i.to_string()) {
    i = i + 1
  }
  base + i.to_string()
}

///|
/// Reject cycles in the Primary dependency graph via a DFS with white/gray/black
/// coloring; a back-edge to a gray node is a cycle.
fn check_no_cycles(res : DepRelationship, n : Int) -> Unit raise SolveError {
  let color = Array::make(n, 0) // 0 = white, 1 = gray (on stack), 2 = black
  let stack : Array[@model.PackageId] = []
  for i in 0..<n {
    if color[i] == 0 {
      dfs(res, @model.PackageId(i), color, stack)
    }
  }
}

///|
fn dfs(
  res : DepRelationship,
  pkg_id : @model.PackageId,
  color : Array[Int],
  stack : Array[@model.PackageId],
) -> Unit raise SolveError {
  let @model.PackageId(i) = pkg_id
  color[i] = 1
  stack.push(pkg_id)
  for entry in res.deps_of_target(BuildTarget::primary(pkg_id)) {
    let (target, _) = entry
    guard target.kind is Primary else { continue }
    let dep = target.pkg
    let @model.PackageId(j) = dep
    if color[j] == 1 {
      // `dep` re-enters the current stack: the cycle is stack[start..] where
      // start is where `dep` sits.
      let start = stack.search(dep).unwrap_or(0)
      raise ImportLoop(cycle=stack[start:].to_owned())
    } else if color[j] == 0 {
      dfs(res, dep, color, stack)
    }
  }
  stack.pop() |> ignore
  color[i] = 2
}

///|
pub fn is_stdlib_import(import_path : String) -> Bool {
  import_path.has_prefix("moonbitlang/core/")
}
