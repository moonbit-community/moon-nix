// Source-file fact scanning. Discovery stays close to Rust moon: it normally
// classifies files by name, and only reads source when it needs package re-export
// facts (`pub using @alias { ... }`) for dependency edges.

///|
/// Content-derived facts about one source file.
pub(all) struct SourceFacts {
  /// Local aliases re-exported by a top-level `pub using @alias {…}` line. The
  /// discoverer resolves each alias against the package's import list to learn
  /// which packages are re-exported (see `DiscoveredPackage::reexports`).
  reexports : Array[String]
}

///|
/// Reads a source file and returns its [`SourceFacts`]. The discoverer calls this
/// once per `.mbt`; an implementation may content-address the result so an
/// unchanged file is never re-read across builds.
pub(open) trait SourceScanner {
  fn scan(Self, path : String) -> SourceFacts
}

///|
/// The trivial scanner: read the file and scan it, every time. The default when
/// no caching is wired (tests, `discover_local_module` without a cache).
pub struct PlainScanner {}

///|
pub extend PlainScanner with SourceScanner::{scan}

///|
pub impl SourceScanner for PlainScanner with fn scan(_self, path) {
  scan_source(@os.read_file(path))
}

///|
/// A disk-backed scanner that content-addresses [`SourceFacts`] by `(path, mtime,
/// size)` over a shared [`@statcache.StatCache`] — the SAME cheap `(mtime, size)`
/// mechanism the rebuilder's content-fingerprint cache uses. An unchanged source file
/// (mtime AND size both match) returns its facts WITHOUT re-reading or re-scanning; a
/// changed one falls through to a full read + scan and re-records.
///
/// Keying on `(mtime, size)` rather than a content digest is the deliberate trade: it
/// avoids reading the file's bytes when unchanged — the very I/O we want to skip — at
/// the cost of NOT sharing facts across identical files / renames (cheap to recompute,
/// rare). The residual unsoundness (same mtime AND size but different content) is the
/// `@statcache` window, shared with the rebuilder.
pub struct CachedScanner {
  cache : @statcache.StatCache
}

///|
pub fn CachedScanner::new(root : String) -> CachedScanner {
  { cache: @statcache.StatCache::new(root) }
}

///|
pub extend CachedScanner with SourceScanner::{scan}

///|
pub impl SourceScanner for CachedScanner with fn scan(self, path) {
  let mt = @os.mtime(path)
  let sz = @os.size(path)
  // Fast path: a recorded payload whose `(mtime, size)` still matches → decode its
  // aliases, no source read. A non-matching tag falls through to a fresh scan, so
  // a stale entry can never mask un-scanned facts.
  match self.cache.lookup(path, mt, sz) {
    Some(payload) => {
      let parts : Array[String] = []
      for p in payload.split(" ") {
        if p.length() > 0 {
          parts.push(p.to_owned())
        }
      }
      if parts.length() >= 1 && parts[0].length() == 3 {
        let b = parts[0].to_array()
        // Tags `3`/`4` are older formats: `<tag><inline><doctest> <reexport>*`
        // with optional `| <linkreq>*`. Ignore the obsolete facts.
        if b[0] == '4' || b[0] == '3' {
          let reexports : Array[String] = []
          for i in 1..<parts.length() {
            if parts[i] == "|" {
              break
            } else {
              reexports.push(parts[i])
            }
          }
          return SourceFacts::{ reexports, }
        }
      }
      if parts.length() >= 1 && parts[0] == "5" {
        let reexports : Array[String] = []
        for i in 1..<parts.length() {
          reexports.push(parts[i])
        }
        return SourceFacts::{ reexports, }
      }
    }
    None => ()
  }
  // Miss: read once, scan once, record payload
  // `5 <alias>*`.
  let facts = scan_source(@os.read_file(path))
  let mut payload = "5"
  for a in facts.reexports {
    payload = payload + " " + a
  }
  self.cache.record(path, mt, sz, payload)
  facts
}

///|
/// Scan a source file's content for package re-export aliases in a single
/// line-by-line pass — a light lexical scan, not a full parse.
///
/// Reads the string by UTF-16 code-unit index (`code_at`, O(1)) rather than
/// materializing an `Array[Char]` — every token we look for is ASCII, so the only
/// allocation this once made (one Char array the size of the whole file) is gone.
/// Every `code_at` below is guarded by a prior `< n` (or `< e <= n`) check.
pub fn scan_source(content : String) -> SourceFacts {
  let n = content.length()
  let sp = ' '.to_int()
  let tab = '\t'.to_int()
  let reexports : Array[String] = []
  let mut i = 0
  while i < n {
    // `i` sits at a line start. Find the first non-blank char `j` and line end `e`.
    let mut j = i
    while j < n && (code_at(content, j) == sp || code_at(content, j) == tab) {
      j = j + 1
    }
    let mut e = j
    while e < n && code_at(content, e) != '\n'.to_int() {
      e = e + 1
    }
    if j < e {
      // A top-level `pub using @alias {…}` re-exports items from the package
      // bound to `alias`. Record the alias (resolved to a package later) so the
      // solver can hand the re-exported package's `.mi` to downstream consumers.
      if matches_word(content, j, "pub") {
        let mut k = j + 3
        while k < e && (code_at(content, k) == sp || code_at(content, k) == tab) {
          k = k + 1
        }
        if matches_word(content, k, "using") {
          k = k + 5
          while k < e &&
                (code_at(content, k) == sp || code_at(content, k) == tab) {
            k = k + 1
          }
          if k < e && code_at(content, k) == '@'.to_int() {
            k = k + 1
            let start = k
            while k < e && is_ident_char(code_at(content, k)) {
              k = k + 1
            }
            if k > start {
              reexports.push(content[start:k].to_owned())
            }
          }
        }
      }
    }
    i = e + 1
  }
  SourceFacts::{ reexports, }
}

///|
/// The UTF-16 code unit at `i`, O(1). Callers guard `i` in bounds, so `get` is
/// always `Some`. We compare raw code units against ASCII: a surrogate code unit
/// never equals an ASCII one, so non-ASCII content (e.g. an emoji in a comment) is
/// correctly ignored — and unlike decoding to `Char`, there is no mid-surrogate
/// `None` to trip over. Uses `String::code_unit_at` (the non-deprecated O(1)
/// accessor; `unsafe_char_at`/`get` are both on the way out).
fn code_at(s : String, i : Int) -> Int {
  s.code_unit_at(i).to_int()
}

///|
/// Whether `word` appears at `content[pos..]` as a whole word (followed by a
/// non-identifier char or end-of-input). Code-unit indexed, no allocation; `word`
/// is ASCII so a 1:1 code-unit compare against `content` is exact.
fn matches_word(content : String, pos : Int, word : String) -> Bool {
  let wn = word.length()
  let n = content.length()
  if pos + wn > n {
    return false
  }
  for k in 0..<wn {
    if code_at(content, pos + k) != code_at(word, k) {
      return false
    }
  }
  let after = pos + wn
  after >= n || !is_ident_char(code_at(content, after))
}

///|
fn is_ident_char(c : Int) -> Bool {
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int()
}
