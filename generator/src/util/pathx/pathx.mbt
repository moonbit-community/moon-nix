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
/// The basename of a real FILESYSTEM path: splits on BOTH `/` and `\`, so it is
/// correct on Windows regardless of which separator a path carries (mymoon mixes
/// them — a `\`-rooted cwd from getcwd joined with `/`-built relatives, plus
/// `\`-joined directory listings). Use this for OS paths; use [`last_seg`] for
/// LOGICAL module/package names (which are `/`-only, and which this would
/// over-split if a name legitimately contained a `\`).
///
/// We split explicitly rather than delegate to `moonbitlang/x/path`'s basename,
/// whose POSIX-vs-Win32 behavior is selected at COMPILE time — a seed not built
/// with `platform=windows` would get the POSIX basename and silently fail to
/// strip a `\`-prefixed name.
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.os_last_seg("C:\\proj/_build/foo.mi"), content="foo.mi")
/// }
/// ```
pub fn os_last_seg(path : String) -> String {
  let after_fwd = match path.rev_split_once("/") {
    Some((_, last)) => last.to_owned()
    None => path
  }
  match after_fwd.rev_split_once("\\") {
    Some((_, last)) => last.to_owned()
    None => after_fwd
  }
}

///|
/// The parent of a logical name (everything before the last `/`). When there is
/// no `/`, returns `none` (default `"."`, matching POSIX `dirname`).
///
/// # Example
/// ```mbt check
/// test {
///   inspect(@pathx.parent("a/b/c"), content="a/b")
///   inspect(@pathx.parent("solo"), content=".")
///   inspect(@pathx.parent("solo", none=""), content="")
/// }
/// ```
pub fn parent(name : String, none? : String = ".") -> String {
  match name.rev_split_once("/") {
    Some((dir, _)) => dir.to_owned()
    None => none
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
/// `(stem, ext?)` of the last segment, split on its final `.`
/// (`foo.core` -> `("foo", Some("core"))`, `foo` -> `("foo", None)`). The
/// directory prefix, if any, is dropped — callers pass bare artifact filenames.
///
/// # Example
/// ```mbt check
/// test {
///   let (stem, ext) = @pathx.stem_ext("foo.core")
///   inspect(stem, content="foo")
///   inspect(ext.unwrap(), content="core")
/// }
/// ```
pub fn stem_ext(name : String) -> (String, String?) {
  let base = last_seg(name)
  match base.rev_split_once(".") {
    Some((stem, e)) => (stem.to_owned(), Some(e.to_owned()))
    None => (base, None)
  }
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
  stem_ext(name).0
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
