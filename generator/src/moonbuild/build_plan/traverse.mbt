// Graph traversal over the solved dependency relationship.

///|
/// Postorder DFS over the dependency graph at BUILD-TARGET granularity (not just
/// `PackageId`): from each root target, follow every outgoing edge — including
/// `Primary -> SubPackage` edges (a `sub-package: true` import) and a SubPackage
/// target's own imports. Returns each reached target once, dependencies first.
///
/// This is what build/check use when sub-packages are in play: a package imported
/// ONLY via its sub-package contributes its `SubPackage` target (and that target's
/// dep closure) WITHOUT pulling in its heavier `Primary` target — which is the
/// whole point of sub-packages (breaking cycles).
fn build_target_closure(
  deps_rel : @pkg_solve.DepRelationship,
  roots : Array[@pkg_solve.BuildTarget],
) -> Array[@pkg_solve.BuildTarget] {
  let order : Array[@pkg_solve.BuildTarget] = []
  let visited : Set[@pkg_solve.BuildTarget] = Set([])
  fn dfs(t : @pkg_solve.BuildTarget) -> Unit {
    if visited.contains(t) {
      return
    }
    visited.add(t)
    for entry in deps_rel.deps_of_target(t) {
      let (to, _) = entry
      dfs(to)
    }
    order.push(t)
  }

  for r in roots {
    dfs(r)
  }
  order
}

///|
fn build_packed_check_target_closure(
  deps : @pkg_solve.PackedCheckDeps,
  package_count : Int,
  roots : Array[@model.PackageId],
) -> Array[@pkg_solve.BuildTarget] {
  let order : Array[@pkg_solve.BuildTarget] = []
  let seen_primary = Array::make(package_count, false)
  let seen_sub = Array::make(package_count, false)
  fn dfs(t : @pkg_solve.BuildTarget) -> Unit {
    let @model.PackageId(i) = t.pkg
    let already_seen = match t.kind {
      SubPackage => seen_sub[i]
      _ => seen_primary[i]
    }
    if already_seen {
      return
    }
    match t.kind {
      SubPackage => seen_sub[i] = true
      _ => seen_primary[i] = true
    }
    for edge in deps.deps_of_target(t) {
      dfs(@pkg_solve.BuildTarget::{ pkg: edge.to, kind: edge.kind })
    }
    order.push(t)
  }

  for r in roots {
    dfs(@pkg_solve.BuildTarget::primary(r))
  }
  order
}

///|
/// Postorder DFS producing the `.core` LINK order from a single `main`, applying
/// virtual-package override substitution: when a node is a virtual package the
/// consumer overrode, the chosen IMPLEMENTATION package is substituted in its
/// place (and its dependency subtree expanded there), so the implementation's
/// `.core` — and its deps — land at the virtual's topological position, with
/// `main` last. A virtual package with no override stays itself (its own default
/// `.core` is linked, or link lowering raises if it also has no default).
///
/// Unlike [`build_target_closure`], the substitution makes this link-specific:
/// the resulting list is the cores to LINK, not the packages to build actions for.
fn link_core_order(
  deps_rel : @pkg_solve.DepRelationship,
  main : @model.PackageId,
  overrides : Map[@model.PackageId, @model.PackageId],
) -> Array[@pkg_solve.BuildTarget] {
  link_core_order_multi(
    deps_rel,
    [@pkg_solve.BuildTarget::primary(main)],
    overrides,
  )
}

///|
/// Like [`link_core_order`] but seeded from MANY roots sharing one visited set —
/// the test link, whose "main" is the synthetic test core (linked separately) and
/// whose link roots are the test target's direct deps. The same virtual-override
/// substitution applies, so an overridden virtual's implementation `.core` lands
/// at the virtual's topological position.
fn link_core_order_multi(
  deps_rel : @pkg_solve.DepRelationship,
  roots : Array[@pkg_solve.BuildTarget],
  overrides : Map[@model.PackageId, @model.PackageId],
) -> Array[@pkg_solve.BuildTarget] {
  let order : Array[@pkg_solve.BuildTarget] = []
  let visited : Set[@pkg_solve.BuildTarget] = Set([])
  fn dfs(t : @pkg_solve.BuildTarget) -> Unit {
    // Substitute an overridden virtual package with its chosen implementation
    // (only `Primary` targets are overridable). A `SubPackage` target links its own
    // `_sub.core` and is followed through its own import edges.
    let node = if t.kind is Primary {
      match overrides.get(t.pkg) {
        Some(impl_pkg_id) => @pkg_solve.BuildTarget::primary(impl_pkg_id)
        None => t
      }
    } else {
      t
    }
    if visited.contains(node) {
      return
    }
    visited.add(node)
    for entry in deps_rel.deps_of_target(node) {
      let (to, _) = entry
      dfs(to)
    }
    order.push(node)
  }

  for r in roots {
    dfs(r)
  }
  order
}
