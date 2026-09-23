// The identity layer shared by every later build stage.

///|
/// Arena handle for a discovered package_name.
/// Only [`PackageTable`] mints these,so indexing back into it is total.
pub(all) struct PackageId(Int) derive(Eq, Hash)

///|
pub extend PackageId with Eq::{not_equal, equal}

///|
pub extend PackageId with Hash::{hash, hash_combine}

///|
/// Arena handle for a module.
pub(all) struct ModuleId(Int) derive(Eq)

///|
pub extend ModuleId with Eq::{not_equal, equal}

///|
/// The package_name path: the part of a package_name's name *within* its module, e.g. `lib/foo`.
/// The empty path denotes the module's root package_name. Segments are joined by `/`.
pub(all) struct PackagePath {
  segments : Array[String]
}

///|
pub fn PackagePath::from_segments(segments : Array[String]) -> PackagePath {
  { segments, }
}

///|
pub fn PackagePath::empty() -> PackagePath {
  { segments: [], }
}

///|
pub fn PackagePath::is_empty(self : PackagePath) -> Bool {
  self.segments.is_empty()
}

///|
/// The last segment — the package_name's short name. `None` for the root package_name.
pub fn PackagePath::short_name(self : PackagePath) -> String? {
  let n = self.segments.length()
  if n == 0 {
    None
  } else {
    Some(self.segments[n - 1])
  }
}

///|
pub fn PackagePath::to_string(self : PackagePath) -> String {
  self.segments.join("/")
}

///|
/// A package_name's fully-qualified name: the module name plus the in-module
/// [`PackagePath`].
pub(all) struct PackageFQN {
  module_name : String
  package_path : PackagePath
}

///|
/// Render as `module_name` for the root package_name, else `module_name/pkg/path`.
pub fn PackageFQN::to_string(self : PackageFQN) -> String {
  if self.package_path.is_empty() {
    self.module_name
  } else {
    self.module_name + "/" + self.package_path.to_string()
  }
}

///|
/// The short import_alias used to reference this package_path: its last path segment, or
/// the module name's last segment for the root package_name.
pub fn PackageFQN::short_alias(self : PackageFQN) -> String {
  match self.package_path.short_name() {
    Some(s) => s
    None => last_segment(self.module_name)
  }
}

///|
/// Whether `self` may import `dependency` under the internal-visibility rule.
/// `internal` packages are only importable within the same module, and only by
/// packages sharing the path prefix up to the (last) `internal` segment. Mirrors
/// moonbuild's `PackagePath::can_import`.
pub fn PackagePath::can_import(
  self : PackagePath,
  dependency : PackagePath,
  same_module : Bool,
) -> Bool {
  can_import_segments(self.segments, dependency.segments, same_module)
}

///|
fn can_import_segments(
  importer : Array[String],
  dependency : Array[String],
  same_module : Bool,
) -> Bool {
  let mut internal_pos = -1
  for i, seg in dependency {
    if seg == "internal" {
      internal_pos = i
    }
  }
  if internal_pos < 0 {
    return true // no internal segment: always importable
  }
  if !same_module {
    return false // internal packages never cross module boundaries
  }
  if importer.length() < internal_pos {
    return false
  }
  for i in 0..<internal_pos {
    if importer[i] != dependency[i] {
      return false
    }
  }
  true
}

///|
/// Whether `self` may import `dependency`.
/// Internal imports only work within the same module.
pub fn PackageFQN::can_import(
  self : PackageFQN,
  dependency : PackageFQN,
) -> Bool {
  let same_module = self.module_name == dependency.module_name
  self.package_path.can_import(dependency.package_path, same_module)
}

///|
/// The last segment of a package/module name (a LOGICAL, always-`/`-separated
/// name — see `@pathx` for why this is not an OS-aware basename).
fn last_segment(name : String) -> String {
  @pathx.last_seg(name)
}
