// The dependency relationship between packages.

///|
/// Which facet of a package_name an edge concerns. Edges point from a dependent
/// (downstream) to a dependency (upstream). Mirrors moonbuild's `TargetKind`.
pub(all) enum TargetKind {
  Primary
  SubPackage
} derive(Eq, Hash)

///|
pub extend TargetKind with Eq::{not_equal, equal}

///|
pub extend TargetKind with Hash::{hash, hash_combine}

///|
/// A package's primary or sub-package build target.
#valtype
pub(all) struct BuildTarget {
  pkg : @model.PackageId
  kind : TargetKind
} derive(Eq, Hash)

///|
pub extend BuildTarget with Eq::{not_equal, equal}

///|
pub extend BuildTarget with Hash::{hash, hash_combine}

///|
/// The `Primary` target of a package_name (the common case).
pub fn BuildTarget::primary(pkg : @model.PackageId) -> BuildTarget {
  { pkg, kind: Primary, }
}

///|
/// A backend condition guarding a dependency edge.
pub(all) enum DepCond {
  Backend(String) //  import {} for "native"
}

///|
/// One dependency edge: the resolved short import_alias the importer refers to the
/// dependency by, plus the import kind it came from.
pub(all) struct DepEdge {
  short_alias : String
  kind : TargetKind
  /// `None` = an unconditional import. `Some(cond)` = a conditional import
  /// (`import {} for "<x>"`) — the edge exists only when the build matches `cond`
  /// (backend). [`DepRelationship::specialize`] drops non-matching ones.
  cond : DepCond?
}

///|
/// Dependency edges between primary and sub-package targets, with virtual
/// implementation and override selections used during linking.
pub struct DepRelationship {
  /// Adjacency: build target -> its direct dependencies (with edge labels). A
  /// key with an empty array is a registered node with no dependencies.
  dep_graph : Map[BuildTarget, Array[(BuildTarget, DepEdge)]]
  /// Virtual-package implementation: an implementation package (declaring
  /// `implement = <virtual>`) -> the virtual package it implements. NOT an import
  /// edge (an impl is never `import`ed); it records the interface a package's
  /// `build-package` must `-check-mi`/`-impl-virtual` against.
  virt_impl : Map[@model.PackageId, @model.PackageId]
  /// Implementation package -> std virtual package FQN (`moonbitlang/core/abort`).
  /// These virtual packages live in the prebuilt std bundle, not in discovery.
  std_virt_impl : Map[@model.PackageId, String]
  /// Per-consumer override selection: consumer package -> (virtual package ->
  /// chosen implementation package). Filled from a package's `overrides = [...]`.
  /// At link time the virtual's slot in the `.core` closure is replaced by the
  /// chosen implementation's `.core`.
  virtual_users : Map[@model.PackageId, Map[@model.PackageId, @model.PackageId]]
  /// Per-consumer std override selections: std virtual FQN -> implementation.
  std_virtual_users : Map[@model.PackageId, Map[String, @model.PackageId]]
  mut has_conditional_edges : Bool
}

///|
pub fn DepRelationship::new() -> DepRelationship {
  {
    dep_graph: {},
    virt_impl: {},
    std_virt_impl: {},
    virtual_users: {},
    std_virtual_users: {},
    has_conditional_edges: false,
  }
}

///|
/// The virtual package that `pkg_id` implements, if `pkg_id` is an implementation.
pub fn DepRelationship::virt_impl_of(
  self : DepRelationship,
  pkg_id : @model.PackageId,
) -> @model.PackageId? {
  self.virt_impl.get(pkg_id)
}

///|
/// The std virtual package FQN that `pkg_id` implements, if any.
pub fn DepRelationship::std_virt_impl_of(
  self : DepRelationship,
  pkg_id : @model.PackageId,
) -> String? {
  self.std_virt_impl.get(pkg_id)
}

///|
/// Whether `pkg_id` is an implementation of some virtual package.
pub fn DepRelationship::is_impl(
  self : DepRelationship,
  pkg_id : @model.PackageId,
) -> Bool {
  self.virt_impl.contains(pkg_id) || self.std_virt_impl.contains(pkg_id)
}

///|
/// `consumer`'s override selections: virtual package -> chosen implementation.
/// Empty when the consumer declares no `overrides`.
pub fn DepRelationship::overrides_of(
  self : DepRelationship,
  consumer : @model.PackageId,
) -> Map[@model.PackageId, @model.PackageId] {
  self.virtual_users.get(consumer).unwrap_or_else(() => {})
}

///|
/// `consumer`'s std override selections: std virtual FQN -> chosen implementation.
pub fn DepRelationship::std_overrides_of(
  self : DepRelationship,
  consumer : @model.PackageId,
) -> Map[String, @model.PackageId] {
  self.std_virtual_users.get(consumer).unwrap_or_else(() => {})
}

///|
/// Register a build target even when it has no dependencies. Idempotent.
pub fn DepRelationship::add_node(
  self : DepRelationship,
  t : BuildTarget,
) -> Unit {
  if self.dep_graph.get(t) is None {
    self.dep_graph[t] = []
  }
}

///|
/// Add an edge `from -> to` (dependent -> dependency) between build targets.
pub fn DepRelationship::add_edge(
  self : DepRelationship,
  from : BuildTarget,
  to : BuildTarget,
  edge : DepEdge,
) -> Unit {
  if edge.cond is Some(_) {
    self.has_conditional_edges = true
  }
  let adj = self.dep_graph.get_or_init(from, () => [])
  adj.push((to, edge))
}

///|
/// Keep unconditional edges and imports for the selected backend.
/// Virtual-package relationships are carried through unchanged.
pub fn DepRelationship::specialize(
  self : DepRelationship,
  backend : String,
) -> DepRelationship {
  if !self.has_conditional_edges {
    return self
  }
  let r = DepRelationship::new()
  for t, adj in self.dep_graph {
    let mut dropped = false
    for entry in adj {
      if !dep_cond_matches(entry.1.cond, backend) {
        dropped = true
        break
      }
    }
    if !dropped {
      r.dep_graph[t] = adj
      for entry in adj {
        if entry.1.cond is Some(_) {
          r.has_conditional_edges = true
          break
        }
      }
    } else {
      let kept : Array[(BuildTarget, DepEdge)] = []
      for entry in adj {
        if dep_cond_matches(entry.1.cond, backend) {
          kept.push(entry)
          if entry.1.cond is Some(_) {
            r.has_conditional_edges = true
          }
        }
      }
      r.dep_graph[t] = kept
    }
  }
  for k, v in self.virt_impl {
    r.virt_impl[k] = v
  }
  for k, v in self.std_virt_impl {
    r.std_virt_impl[k] = v
  }
  for k, v in self.virtual_users {
    r.virtual_users[k] = v
  }
  for k, v in self.std_virtual_users {
    r.std_virtual_users[k] = v
  }
  r
}

///|
fn dep_cond_matches(
  cond : DepCond?,
  backend : String,
) -> Bool {
  match cond {
    None => true
    Some(Backend(b)) => b == backend

  }
}

///|
/// The direct dependencies of build target `t` (empty if none / unregistered).
pub fn DepRelationship::deps_of_target(
  self : DepRelationship,
  t : BuildTarget,
) -> Array[(BuildTarget, DepEdge)] {
  self.dep_graph.get(t).unwrap_or_else(() => [])
}

///|
/// The direct Primary dependencies of `pkg`'s Primary target, as package_name ids — the
/// view build/lib/check use. (Test edges never originate from a Primary target, so
/// this returns exactly the build-relevant deps, unchanged from the pre-test
/// graph.)
pub fn DepRelationship::deps_of(
  self : DepRelationship,
  pkg : @model.PackageId,
) -> Array[(@model.PackageId, DepEdge)] {
  let out : Array[(@model.PackageId, DepEdge)] = []
  for entry in self.deps_of_target(BuildTarget::primary(pkg)) {
    let (t, edge) = entry
    if t.kind is Primary {
      out.push((t.pkg, edge))
    }
  }
  out
}

///|
/// Raised while solving the package_name dependency graph. Mirrors the subset of
/// moonbuild's `SolveError` reachable from regular (non-virtual) imports.
pub suberror SolveError {
  /// An import path matches no discovered package_name.
  ImportNotFound(import_path~ : String, package_name~ : String)
  /// A cycle in the Primary dependency graph: the packages on the cycle in
  /// dependency order, closing back on the first (e.g. `[a, b]` means
  /// `a -> b -> a`). Kept structural; the boundary renders it if/when needed.
  ImportLoop(cycle~ : Array[@model.PackageId])
  /// An `internal` package_name imported from outside its allowed prefix.
  InternalImportForbidden(importer~ : String, dependency~ : String)
  /// Two imports collapse to the same short import_alias within one package_name.
  ConflictingImportAlias(
    import_alias~ : String,
    package_name~ : String,
    first~ : String,
    second~ : String
  )
  /// `implement = <target>` names a package that is not itself a virtual package.
  ImplementTargetNotVirtual(package_name~ : String, target~ : String)
  /// A package `import`s an implementation package directly — forbidden; consumers
  /// import the VIRTUAL interface and select the impl via `overrides`.
  CannotImportVirtualImplementation(importer~ : String, dependency~ : String)
  /// An `overrides` entry names a package that does not implement any virtual
  /// package (so there is nothing for it to override).
  OverrideNotImplementor(package_name~ : String, override_~ : String)
  /// Two `overrides` entries both claim to implement the SAME virtual package.
  VirtualOverrideConflict(
    package_name~ : String,
    virtual_pkg~ : String,
    first~ : String,
    second~ : String
  )
}
