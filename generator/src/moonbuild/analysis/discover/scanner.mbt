// Source-file fact scanning. Discovery stays close to Rust moon: it normally
// classifies files by name, and only reads source when it needs package re-export
// facts (`pub using @alias { ... }`) for dependency edges.

///|
/// Content-derived facts about one source file.
pub(all) struct SourceFacts {
  /// Local aliases re-exported by a top-level `pub using @alias {…}` line. The
  /// discoverer resolves each alias against the package's import list to learn
  /// which packages are re-exported (see `Package::reexports`).
  reexports : Array[String]
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
