// Graph traversal over the solved dependency relationship.

///|
/// Postorder DFS over the dependency graph at BUILD-TARGET granularity (not just
/// `PackageId`): from each root target, follow every outgoing edge — including
/// `Primary -> SubPackage` edges (a `sub-package: true` import) and a SubPackage
/// target's own imports. Returns each reached target once, dependencies first.
///
/// This is what build planning uses when sub-packages are in play: a package imported
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
/// Dependency-first link order for one executable, substituting the consumer's
/// selected implementations for virtual packages.
fn link_core_order(
  deps_rel : @pkg_solve.DepRelationship,
  main : @model.PackageId,
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

  dfs(@pkg_solve.BuildTarget::primary(main))
  order
}
