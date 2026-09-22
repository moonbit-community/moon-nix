// The dependency relationship between packages.

///|
/// Which facet of a package_name an edge concerns. Edges point from a dependent
/// (downstream) to a dependency (upstream). Mirrors moonbuild's `TargetKind`.
pub(all) enum TargetKind {
  Primary
  WhiteboxTest
  BlackboxTest
  InlineTest
  SubPackage
} derive(Eq, Hash)

///|
pub extend TargetKind with Eq::{not_equal, equal}

///|
pub extend TargetKind with Hash::{hash, hash_combine}

///|
/// A node in the dependency graph: one facet of one package_name. A package_name splits
/// into up to several build targets (its `Primary`, plus `WhiteboxTest` /
/// `BlackboxTest` / … when it has the corresponding test files). The `Primary`
/// target is the package_name proper; everything build/lib/check needs is the Primary
/// subgraph, reachable via [`DepRelationship::deps_of`].
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
  { pkg, kind: Primary }
}

///|
/// The condition guarding a conditional dependency edge (`import {} for "<x>"`):
/// either a backend name (`native`/`wasm-gc`/…) or a platform spec
/// (`linux`/`windows-gnu`/…). The two name-spaces don't overlap, so the section
/// string classifies unambiguously. [`DepRelationship::specialize`] keeps the edge
/// only when the active build matches.
pub(all) enum DepCond {
  Backend(String) //  import {} for "native"
  Platform(String) // import {} for "windows-gnu"
}

///|
/// One dependency edge: the resolved short import_alias the importer refers to the
/// dependency by, plus the import kind it came from.
pub(all) struct DepEdge {
  short_alias : String
  kind : TargetKind
  /// `None` = an unconditional import. `Some(cond)` = a conditional import
  /// (`import {} for "<x>"`) — the edge exists only when the build matches `cond`
  /// (backend or platform). [`DepRelationship::specialize`] drops non-matching ones.
  cond : DepCond?
}

///|
/// The resolved dependency graph over build targets. Edges point dependent ->
/// dependency. The `Primary` subgraph is what build/lib/check consume (via the
/// [`deps_of`] convenience); test targets (`WhiteboxTest`/`BlackboxTest`) are
/// extra nodes that point INTO the Primary subgraph and are never depended upon,
/// so they are leaves a test build pulls in on demand.
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
/// A compact dependency view for `moon check` hot path. It stores only the
/// `solve_without_tests` graph facets check consumes: Primary/SubPackage edges
/// and implementation -> virtual-interface wiring.
pub struct PackedCheckDeps {
  primary : Array[Array[PackedCheckEdge]]
  sub : Array[Array[PackedCheckEdge]]
  virt_impl : Array[@model.PackageId?]
  std_virt_impl : Array[String?]
  has_conditional_edges : Bool
}

///|
pub(all) struct PackedCheckEdge {
  to : @model.PackageId
  kind : TargetKind
  short_alias : String
  cond : DepCond?
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
pub fn PackedCheckDeps::from_dep_relationship(
  deps : DepRelationship,
  package_count : Int,
) -> PackedCheckDeps {
  let primary : Array[Array[PackedCheckEdge]] = []
  let sub : Array[Array[PackedCheckEdge]] = []
  let virt_impl : Array[@model.PackageId?] = []
  let std_virt_impl : Array[String?] = []
  let mut has_conditional_edges = false
  for i in 0..<package_count {
    let pkg = @model.PackageId(i)
    let (primary_edges, primary_has_cond) = packed_edges_from(
      deps,
      BuildTarget::primary(pkg),
    )
    primary.push(primary_edges)
    let (sub_edges, sub_has_cond) = packed_edges_from(deps, BuildTarget::{
      pkg,
      kind: SubPackage,
    })
    sub.push(sub_edges)
    if primary_has_cond || sub_has_cond {
      has_conditional_edges = true
    }
    virt_impl.push(deps.virt_impl_of(pkg))
    std_virt_impl.push(deps.std_virt_impl_of(pkg))
  }
  { primary, sub, virt_impl, std_virt_impl, has_conditional_edges }
}

///|
fn packed_edges_from(
  deps : DepRelationship,
  target : BuildTarget,
) -> (Array[PackedCheckEdge], Bool) {
  let out : Array[PackedCheckEdge] = []
  let mut has_conditional_edges = false
  for entry in deps.deps_of_target(target) {
    let (to, edge) = entry
    if edge.cond is Some(_) {
      has_conditional_edges = true
    }
    out.push({
      to: to.pkg,
      kind: to.kind,
      short_alias: edge.short_alias,
      cond: edge.cond,
    })
  }
  (out, has_conditional_edges)
}

///|
pub fn PackedCheckDeps::virt_impl_of(
  self : PackedCheckDeps,
  pkg_id : @model.PackageId,
) -> @model.PackageId? {
  let @model.PackageId(i) = pkg_id
  self.virt_impl[i]
}

///|
pub fn PackedCheckDeps::std_virt_impl_of(
  self : PackedCheckDeps,
  pkg_id : @model.PackageId,
) -> String? {
  let @model.PackageId(i) = pkg_id
  self.std_virt_impl[i]
}

///|
pub fn PackedCheckDeps::deps_of_target(
  self : PackedCheckDeps,
  target : BuildTarget,
) -> Array[PackedCheckEdge] {
  let @model.PackageId(i) = target.pkg
  match target.kind {
    SubPackage => self.sub[i]
    _ => self.primary[i]
  }
}

///|
pub fn PackedCheckDeps::specialize(
  self : PackedCheckDeps,
  backend : String,
  platform : @os.Platform,
) -> PackedCheckDeps {
  if !self.has_conditional_edges {
    return self
  }
  let primary : Array[Array[PackedCheckEdge]] = []
  let sub : Array[Array[PackedCheckEdge]] = []
  let mut has_conditional_edges = false
  for adj in self.primary {
    let (kept, has_cond) = packed_edges_specialized(adj, backend, platform)
    primary.push(kept)
    if has_cond {
      has_conditional_edges = true
    }
  }
  for adj in self.sub {
    let (kept, has_cond) = packed_edges_specialized(adj, backend, platform)
    sub.push(kept)
    if has_cond {
      has_conditional_edges = true
    }
  }
  {
    primary,
    sub,
    virt_impl: self.virt_impl,
    std_virt_impl: self.std_virt_impl,
    has_conditional_edges,
  }
}

///|
fn packed_edges_specialized(
  adj : Array[PackedCheckEdge],
  backend : String,
  platform : @os.Platform,
) -> (Array[PackedCheckEdge], Bool) {
  let out : Array[PackedCheckEdge] = []
  let mut has_conditional_edges = false
  for edge in adj {
    if dep_cond_matches(edge.cond, backend, platform) {
      out.push(edge)
      if edge.cond is Some(_) {
        has_conditional_edges = true
      }
    }
  }
  (out, has_conditional_edges)
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
/// Register a node with no edges yet (so an edgeless test target still exists in
/// the graph). Idempotent.
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
/// A build-specialized view of the graph: every unconditional edge is kept, and
/// each conditional edge (`cond = Some(...)`, from `import {} for "<x>"`) is kept
/// only when the active build matches — a `Backend(b)` edge when `b == backend`, a
/// `Platform(p)` edge when the active `platform` matches `p`. Build planning calls
/// this once with the active backend + platform so all downstream traversals
/// (closure, compile imports, link order) see exactly the edges that apply —
/// keeping a leaf package's other-backend/other-OS imports out of THIS build's
/// closure (so they don't poison supported-targets). `virt_impl` / `virtual_users`
/// are condition-agnostic and carried through.
pub fn DepRelationship::specialize(
  self : DepRelationship,
  backend : String,
  platform : @os.Platform,
) -> DepRelationship {
  if !self.has_conditional_edges {
    return self
  }
  let r = DepRelationship::new()
  for t, adj in self.dep_graph {
    let mut dropped = false
    for entry in adj {
      if !dep_cond_matches(entry.1.cond, backend, platform) {
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
        if dep_cond_matches(entry.1.cond, backend, platform) {
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
  platform : @os.Platform,
) -> Bool {
  match cond {
    None => true
    Some(Backend(b)) => b == backend
    Some(Platform(p)) =>
      // unparseable platform spec -> drop the edge conservatively
      @os.Platform::parse(p) is Some(c) && platform.matches(c)
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
/// Every test target (`WhiteboxTest`/`BlackboxTest`/`InlineTest`) in the graph —
/// the roots a test build demands. (A test build's lowering will consume these.)
pub fn DepRelationship::test_targets(
  self : DepRelationship,
) -> Array[BuildTarget] {
  let out : Array[BuildTarget] = []
  for t, _ in self.dep_graph {
    match t.kind {
      WhiteboxTest | BlackboxTest | InlineTest => out.push(t)
      _ => ()
    }
  }
  out
}

///|
/// Total number of dependency edges in the graph (all targets).
pub fn DepRelationship::edge_count(self : DepRelationship) -> Int {
  let mut n = 0
  for _, adj in self.dep_graph {
    n = n + adj.length()
  }
  n
}

///|
fn cache_write_int(sb : StringBuilder, n : Int) -> Unit {
  sb.write_string(n.to_string())
  sb.write_string(":")
}

///|
fn cache_write_string(sb : StringBuilder, s : String) -> Unit {
  cache_write_int(sb, s.length())
  sb.write_string(s)
}

///|
fn cache_write_bool(sb : StringBuilder, b : Bool) -> Unit {
  sb.write_string(if b { "T" } else { "F" })
}

///|
priv struct CacheReader {
  text : String
  mut pos : Int
}

///|
fn cache_reader_read_byte(reader : CacheReader) -> Int? {
  guard reader.pos < reader.text.length() else { return None }
  let c = reader.text.code_unit_at(reader.pos).to_int()
  reader.pos = reader.pos + 1
  Some(c)
}

///|
fn cache_reader_read_int(reader : CacheReader) -> Int? {
  let mut n = 0
  let mut saw_digit = false
  for ;; {
    guard reader.pos < reader.text.length() else { return None }
    let c = reader.text.code_unit_at(reader.pos).to_int()
    if c == ':'.to_int() {
      guard saw_digit else { return None }
      reader.pos = reader.pos + 1
      return Some(n)
    }
    guard c >= '0'.to_int() && c <= '9'.to_int() else { return None }
    saw_digit = true
    n = n * 10 + (c - '0'.to_int())
    reader.pos = reader.pos + 1
  }
}

///|
fn cache_reader_read_string(reader : CacheReader) -> String? {
  let n = match cache_reader_read_int(reader) {
    Some(value) => value
    None => return None
  }
  guard n >= 0 && reader.pos + n <= reader.text.length() else { return None }
  let s = reader.text[reader.pos:reader.pos + n].to_owned()
  reader.pos = reader.pos + n
  Some(s)
}

///|
fn cache_reader_read_bool(reader : CacheReader) -> Bool? {
  match cache_reader_read_byte(reader) {
    Some(c) if c == 'T'.to_int() => Some(true)
    Some(c) if c == 'F'.to_int() => Some(false)
    _ => None
  }
}

///|
fn package_id_to_int(id : @model.PackageId) -> Int {
  let @model.PackageId(i) = id
  i
}

///|
fn target_kind_to_int(kind : TargetKind) -> Int {
  match kind {
    Primary => 0
    WhiteboxTest => 1
    BlackboxTest => 2
    InlineTest => 3
    SubPackage => 4
  }
}

///|
fn target_kind_from_int(i : Int) -> TargetKind? {
  match i {
    0 => Some(Primary)
    1 => Some(WhiteboxTest)
    2 => Some(BlackboxTest)
    3 => Some(InlineTest)
    4 => Some(SubPackage)
    _ => None
  }
}

///|
fn cache_write_target(sb : StringBuilder, target : BuildTarget) -> Unit {
  cache_write_int(sb, package_id_to_int(target.pkg))
  cache_write_int(sb, target_kind_to_int(target.kind))
}

///|
fn cache_reader_read_target(reader : CacheReader) -> BuildTarget? {
  let pkg = match cache_reader_read_int(reader) {
    Some(i) => @model.PackageId(i)
    None => return None
  }
  let kind = match cache_reader_read_int(reader) {
    Some(i) =>
      match target_kind_from_int(i) {
        Some(kind) => kind
        None => return None
      }
    None => return None
  }
  Some({ pkg, kind })
}

///|
fn cache_write_cond(sb : StringBuilder, cond : DepCond?) -> Unit {
  match cond {
    None => cache_write_int(sb, 0)
    Some(Backend(s)) => {
      cache_write_int(sb, 1)
      cache_write_string(sb, s)
    }
    Some(Platform(s)) => {
      cache_write_int(sb, 2)
      cache_write_string(sb, s)
    }
  }
}

///|
fn cache_reader_read_cond(reader : CacheReader) -> DepCond?? {
  match cache_reader_read_int(reader) {
    Some(0) => Some(None)
    Some(1) =>
      match cache_reader_read_string(reader) {
        Some(s) => Some(Some(Backend(s)))
        None => None
      }
    Some(2) =>
      match cache_reader_read_string(reader) {
        Some(s) => Some(Some(Platform(s)))
        None => None
      }
    _ => None
  }
}

///|
fn cache_write_edge(sb : StringBuilder, edge : DepEdge) -> Unit {
  cache_write_string(sb, edge.short_alias)
  cache_write_int(sb, target_kind_to_int(edge.kind))
  cache_write_cond(sb, edge.cond)
}

///|
fn cache_reader_read_edge(reader : CacheReader) -> DepEdge? {
  let short_alias = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let kind = match cache_reader_read_int(reader) {
    Some(i) =>
      match target_kind_from_int(i) {
        Some(kind) => kind
        None => return None
      }
    None => return None
  }
  let cond = match cache_reader_read_cond(reader) {
    Some(c) => c
    None => return None
  }
  Some({ short_alias, kind, cond })
}

///|
pub fn DepRelationship::to_cache_text(self : DepRelationship) -> String {
  let sb = StringBuilder()
  cache_write_int(sb, self.dep_graph.length())
  for target, adj in self.dep_graph {
    cache_write_target(sb, target)
    cache_write_int(sb, adj.length())
    for entry in adj {
      let (to, edge) = entry
      cache_write_target(sb, to)
      cache_write_edge(sb, edge)
    }
  }
  cache_write_int(sb, self.virt_impl.length())
  for k, v in self.virt_impl {
    cache_write_int(sb, package_id_to_int(k))
    cache_write_int(sb, package_id_to_int(v))
  }
  cache_write_int(sb, self.std_virt_impl.length())
  for k, v in self.std_virt_impl {
    cache_write_int(sb, package_id_to_int(k))
    cache_write_string(sb, v)
  }
  cache_write_int(sb, self.virtual_users.length())
  for user, selections in self.virtual_users {
    cache_write_int(sb, package_id_to_int(user))
    cache_write_int(sb, selections.length())
    for virtual_pkg, impl_pkg in selections {
      cache_write_int(sb, package_id_to_int(virtual_pkg))
      cache_write_int(sb, package_id_to_int(impl_pkg))
    }
  }
  cache_write_int(sb, self.std_virtual_users.length())
  for user, selections in self.std_virtual_users {
    cache_write_int(sb, package_id_to_int(user))
    cache_write_int(sb, selections.length())
    for virtual_pkg, impl_pkg in selections {
      cache_write_string(sb, virtual_pkg)
      cache_write_int(sb, package_id_to_int(impl_pkg))
    }
  }
  cache_write_bool(sb, self.has_conditional_edges)
  sb.to_string()
}

///|
pub fn DepRelationship::from_cache_text(text : String) -> DepRelationship? {
  let reader = { text, pos: 0 }
  let res = DepRelationship::new()
  let graph_len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard graph_len >= 0 else { return None }
  for _ in 0..<graph_len {
    let target = match cache_reader_read_target(reader) {
      Some(t) => t
      None => return None
    }
    let edge_len = match cache_reader_read_int(reader) {
      Some(n) => n
      None => return None
    }
    guard edge_len >= 0 else { return None }
    let adj : Array[(BuildTarget, DepEdge)] = []
    for _ in 0..<edge_len {
      let to = match cache_reader_read_target(reader) {
        Some(t) => t
        None => return None
      }
      let edge = match cache_reader_read_edge(reader) {
        Some(e) => e
        None => return None
      }
      adj.push((to, edge))
    }
    res.dep_graph[target] = adj
  }
  let virt_len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard virt_len >= 0 else { return None }
  for _ in 0..<virt_len {
    let k = match cache_reader_read_int(reader) {
      Some(i) => @model.PackageId(i)
      None => return None
    }
    let v = match cache_reader_read_int(reader) {
      Some(i) => @model.PackageId(i)
      None => return None
    }
    res.virt_impl[k] = v
  }
  let std_virt_len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard std_virt_len >= 0 else { return None }
  for _ in 0..<std_virt_len {
    let k = match cache_reader_read_int(reader) {
      Some(i) => @model.PackageId(i)
      None => return None
    }
    let v = match cache_reader_read_string(reader) {
      Some(s) => s
      None => return None
    }
    res.std_virt_impl[k] = v
  }
  let users_len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard users_len >= 0 else { return None }
  for _ in 0..<users_len {
    let user = match cache_reader_read_int(reader) {
      Some(i) => @model.PackageId(i)
      None => return None
    }
    let selection_len = match cache_reader_read_int(reader) {
      Some(n) => n
      None => return None
    }
    guard selection_len >= 0 else { return None }
    let selections : Map[@model.PackageId, @model.PackageId] = Map([])
    for _ in 0..<selection_len {
      let virtual_pkg = match cache_reader_read_int(reader) {
        Some(i) => @model.PackageId(i)
        None => return None
      }
      let impl_pkg = match cache_reader_read_int(reader) {
        Some(i) => @model.PackageId(i)
        None => return None
      }
      selections[virtual_pkg] = impl_pkg
    }
    res.virtual_users[user] = selections
  }
  let std_users_len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard std_users_len >= 0 else { return None }
  for _ in 0..<std_users_len {
    let user = match cache_reader_read_int(reader) {
      Some(i) => @model.PackageId(i)
      None => return None
    }
    let selection_len = match cache_reader_read_int(reader) {
      Some(n) => n
      None => return None
    }
    guard selection_len >= 0 else { return None }
    let selections : Map[String, @model.PackageId] = Map([])
    for _ in 0..<selection_len {
      let virtual_pkg = match cache_reader_read_string(reader) {
        Some(s) => s
        None => return None
      }
      let impl_pkg = match cache_reader_read_int(reader) {
        Some(i) => @model.PackageId(i)
        None => return None
      }
      selections[virtual_pkg] = impl_pkg
    }
    res.std_virtual_users[user] = selections
  }
  let has_conditional_edges = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  res.has_conditional_edges = has_conditional_edges
  guard reader.pos == text.length() else { return None }
  Some(res)
}

///|
fn cache_write_packed_edge(sb : StringBuilder, edge : PackedCheckEdge) -> Unit {
  cache_write_int(sb, package_id_to_int(edge.to))
  cache_write_int(sb, target_kind_to_int(edge.kind))
  cache_write_string(sb, edge.short_alias)
  cache_write_cond(sb, edge.cond)
}

///|
fn cache_reader_read_packed_edge(reader : CacheReader) -> PackedCheckEdge? {
  let to = match cache_reader_read_int(reader) {
    Some(i) => @model.PackageId(i)
    None => return None
  }
  let kind = match cache_reader_read_int(reader) {
    Some(i) =>
      match target_kind_from_int(i) {
        Some(kind) => kind
        None => return None
      }
    None => return None
  }
  let short_alias = match cache_reader_read_string(reader) {
    Some(s) => s
    None => return None
  }
  let cond = match cache_reader_read_cond(reader) {
    Some(c) => c
    None => return None
  }
  Some({ to, kind, short_alias, cond })
}

///|
fn cache_write_packed_adj(
  sb : StringBuilder,
  adj : Array[PackedCheckEdge],
) -> Unit {
  cache_write_int(sb, adj.length())
  for edge in adj {
    cache_write_packed_edge(sb, edge)
  }
}

///|
fn cache_reader_read_packed_adj(
  reader : CacheReader,
) -> Array[PackedCheckEdge]? {
  let len = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard len >= 0 else { return None }
  let adj : Array[PackedCheckEdge] = []
  for _ in 0..<len {
    match cache_reader_read_packed_edge(reader) {
      Some(edge) => adj.push(edge)
      None => return None
    }
  }
  Some(adj)
}

///|
pub fn PackedCheckDeps::to_cache_text(self : PackedCheckDeps) -> String {
  let sb = StringBuilder()
  cache_write_int(sb, self.primary.length())
  for adj in self.primary {
    cache_write_packed_adj(sb, adj)
  }
  for adj in self.sub {
    cache_write_packed_adj(sb, adj)
  }
  for v in self.virt_impl {
    match v {
      Some(id) => {
        cache_write_bool(sb, true)
        cache_write_int(sb, package_id_to_int(id))
      }
      None => cache_write_bool(sb, false)
    }
  }
  for v in self.std_virt_impl {
    match v {
      Some(s) => {
        cache_write_bool(sb, true)
        cache_write_string(sb, s)
      }
      None => cache_write_bool(sb, false)
    }
  }
  cache_write_bool(sb, self.has_conditional_edges)
  sb.to_string()
}

///|
pub fn PackedCheckDeps::from_cache_text(text : String) -> PackedCheckDeps? {
  let reader = { text, pos: 0 }
  let package_count = match cache_reader_read_int(reader) {
    Some(n) => n
    None => return None
  }
  guard package_count >= 0 else { return None }
  let primary : Array[Array[PackedCheckEdge]] = []
  let sub : Array[Array[PackedCheckEdge]] = []
  let virt_impl : Array[@model.PackageId?] = []
  let std_virt_impl : Array[String?] = []
  for _ in 0..<package_count {
    match cache_reader_read_packed_adj(reader) {
      Some(adj) => primary.push(adj)
      None => return None
    }
  }
  for _ in 0..<package_count {
    match cache_reader_read_packed_adj(reader) {
      Some(adj) => sub.push(adj)
      None => return None
    }
  }
  for _ in 0..<package_count {
    match cache_reader_read_bool(reader) {
      Some(true) =>
        match cache_reader_read_int(reader) {
          Some(i) => virt_impl.push(Some(@model.PackageId(i)))
          None => return None
        }
      Some(false) => virt_impl.push(None)
      None => return None
    }
  }
  for _ in 0..<package_count {
    match cache_reader_read_bool(reader) {
      Some(true) =>
        match cache_reader_read_string(reader) {
          Some(s) => std_virt_impl.push(Some(s))
          None => return None
        }
      Some(false) => std_virt_impl.push(None)
      None => return None
    }
  }
  let has_conditional_edges = match cache_reader_read_bool(reader) {
    Some(b) => b
    None => return None
  }
  guard reader.pos == text.length() else { return None }
  Some({ primary, sub, virt_impl, std_virt_impl, has_conditional_edges })
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
