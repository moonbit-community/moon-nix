// POSIX-only string utilities for LOGICAL paths (module/package names, artifact
// stems). See `moon.pkg` for why these are NOT the same as OS-path operations.

///|
/// The last `/`-separated segment of a logical name (`a/b/c` -> `c`).
/// Splits on `/` only, so it is correct regardless of OS — an OS-aware basename
/// mis-splits names like `encoding/utf8` on Windows.
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.last_seg("encoding/utf8"), content="utf8")
///   inspect(@pathx.last_seg("solo"), content="solo")
/// }
/// ```
pub fn last_seg(name : String) -> String {
  match name.rev_split_once("/") {
    Some((_, last)) => last.to_owned()
    None => name
  }
}

///|
/// Join logical segments with `/`, dropping empty segments
/// (`["a", "", "b/c"]` -> `"a/b/c"`). POSIX-only; segments should not carry
/// surrounding slashes.
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.join(["a", "", "b"]), content="a/b")
/// }
/// ```
pub fn join(segments : Array[String]) -> String {
  segments.filter(s => s != "").join("/")
}

///|
/// The last segment without its extension (`a/b.core` -> `b`). The directory
/// prefix is dropped.
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.stem("a/b.core"), content="b")
/// }
/// ```
pub fn stem(name : String) -> String {
  let base = last_seg(name)
  match base.rev_split_once(".") {
    Some((stem, _)) => stem.to_owned()
    None => base
  }
}

///|
/// If `path` is under directory `base`, return the part after `base/`; else
/// `None`. A cheap prefix-based relativize against a known parent — unlike a full
/// `..`-aware `relative`.
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.strip_under("base/sub/x", "base").unwrap(), content="sub/x")
///   inspect(@pathx.strip_under("other/x", "base") is None, content="true")
/// }
/// ```
pub fn strip_under(path : String, base : String) -> String? {
  match path.strip_prefix(base + "/") {
    Some(rest) => Some(rest.to_owned())
    None => None
  }
}
