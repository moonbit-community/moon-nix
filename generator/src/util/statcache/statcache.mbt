// A disk-backed cache keyed on a file's CHEAP stat signature `(mtime, size)`.
// Entries are loaded into memory from a single append-only `stat.db`. A lookup
// returns the recorded payload iff BOTH mtime and size still match — the file is
// unchanged by the cheap key — else `None` (changed / never seen), and the caller
// recomputes + records.
//
// The payload is an OPAQUE string; each consumer owns its own encoding (a content
// digest, packed source facts, …). This package is ONLY the `(mtime, size)`-keyed
// storage mechanism — what is cached and how it is parsed lives with the user. Both
// the rebuilder's content-fingerprint cache and discovery's source-fact cache are
// thin wrappers over this.

///|
pub struct StatCache {
  root : String
  index : Map[String, StatEntry]
}

///|
pub struct StatEntry {
  mtime : Int64
  size : Int64
  payload : String
}

///|
pub fn StatCache::new(root : String) -> StatCache {
  @os.mkdir_p(root)
  { root, index: load_stat_index(stat_db_path(root)) }
}

///|
fn parse_i64_decimal(s : StringView) -> Int64 {
  let mut n = 0L
  guard s.length() > 0 else { return -1L }
  for c in s {
    guard c.is_ascii_digit() else { return -1L }
    n = n * 10L + Int64::from_int(c.to_int() - '0'.to_int())
  }
  n
}

///|
/// The stable key for `path`: the path hashed so `/` is not a directory separator
/// and the db line does not need escaping for path bytes.
fn entry_key(path : String) -> String {
  @digest.from_string(path).to_string()
}

///|
fn stat_db_path(root : String) -> String {
  root + "/stat.db"
}

///|
fn parse_stat_record(line : String) -> (String, StatEntry)? {
  match line.split_once("\t") {
    Some((tag, rest)) =>
      if tag == "stat" {
        match rest.split_once("\t") {
          Some((key, rest)) =>
            match rest.split_once("\t") {
              Some((mtime_s, rest)) =>
                match rest.split_once("\t") {
                  Some((size_s, payload)) => {
                    let mtime = parse_i64_decimal(mtime_s)
                    let size = parse_i64_decimal(size_s)
                    guard mtime >= 0L && size >= 0L else { return None }
                    Some(
                      (
                        key.to_owned(),
                        { mtime, size, payload: payload.to_owned() },
                      ),
                    )
                  }
                  None => None
                }
              None => None
            }
          None => None
        }
      } else {
        None
      }
    None => None
  }
}

///|
fn load_stat_index(db_path : String) -> Map[String, StatEntry] {
  let index : Map[String, StatEntry] = Map([])
  guard @os.exists(db_path) else { return index }
  for raw in @os.read_file(db_path).split("\n") {
    let line = raw.trim()
    guard line != "" else { continue }
    match parse_stat_record(line.to_owned()) {
      Some((key, entry)) => index[key] = entry
      None => ()
    }
  }
  index
}

///|
fn encode_stat_record(key : String, entry : StatEntry) -> String {
  "stat\t\{key}\t\{entry.mtime}\t\{entry.size}\t\{entry.payload}\n"
}

///|
fn stat_entries_equal(a : StatEntry, b : StatEntry) -> Bool {
  a.mtime == b.mtime && a.size == b.size && a.payload == b.payload
}

///|
/// The recorded payload for `path` iff the recorded `(mtime, size)` matches the
/// passed-in one; else `None`. A changed file, a corrupt record, or a missing
/// entry all miss.
pub fn StatCache::lookup(
  self : StatCache,
  path : String,
  mtime : Int64,
  size : Int64,
) -> String? {
  let key = entry_key(path)
  match self.index.get(key) {
    Some(entry) =>
      if entry.mtime == mtime && entry.size == size {
        return Some(entry.payload)
      }
    None => ()
  }
  None
}

///|
/// Record `(mtime, size) -> payload` for `path` (write-through, so it persists with
/// no flush hook needed).
pub fn StatCache::record(
  self : StatCache,
  path : String,
  mtime : Int64,
  size : Int64,
  payload : String,
) -> Unit {
  let key = entry_key(path)
  let entry = { mtime, size, payload }
  match self.index.get(key) {
    Some(old) => if stat_entries_equal(old, entry) { return }
    None => ()
  }
  self.index[key] = entry
  @os.append_file(stat_db_path(self.root), encode_stat_record(key, entry))
}
