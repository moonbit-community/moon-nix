///|
/// The version source MVS resolves against: for a module, every available version
/// mapped to that version's own transitive requirements. `None` = the module is
/// unknown to the registry. The real impl reads the index's `<user>/<name>.index`
/// (JSON-lines, one moon.mod per version); tests inject a mock.
pub(open) trait Registry {
  fn all_versions_of(Self, name : String) -> Map[
    String,
    Array[@config.Dependency],
  ]? raise ResolveError
}

///|
fn mvs_timing_enabled() -> Bool {
  @unix.getenv("MYMOON_TIMING") is Some("1")
}

///|
fn mvs_timing_ms(start : Int64) -> Int64 {
  (@unix.now_ns() - start) / 1_000_000
}

///|
fn mvs_timing_log(label : String, start : Int64) -> Unit {
  mvs_timing_log_ms(label, mvs_timing_ms(start))
}

///|
fn mvs_timing_log_ms(label : String, ms : Int64) -> Unit {
  if mvs_timing_enabled() && ms > 0 {
    @os.eprintln("timing \{label}: \{ms}ms")
  }
}

///|
/// rust moon `mvs_requirement_matches`: `candidate` satisfies `required` iff it is
/// `>= required` AND in the same compatibility set.
fn mvs_requirement_matches(required : SemVer, candidate : SemVer) -> Bool {
  if candidate.cmp(required) < 0 {
    return false
  }
  if required.major < 2 {
    candidate.major < 2
  } else {
    candidate.major == required.major
  }
}

///|
/// rust moon `select_min_version_satisfying`: the MIN available version satisfying
/// `required` (scan low→high, first match). `None` = nothing satisfies.
fn select_min_version_satisfying(
  required : String,
  available : Array[String],
) -> String? {
  let req = parse_semver(required)
  let sorted = available.copy()
  sorted.sort_by(fn(a, b) { parse_semver(a).cmp(parse_semver(b)) })
  for v in sorted {
    if mvs_requirement_matches(req, parse_semver(v)) {
      return Some(v)
    }
  }
  None
}

///|
/// rust moon-aligned MVS resolution over a `Registry`. Walks the requirement graph
/// from `root_deps`, resolving each requirement to its MIN available satisfying
/// version and recursing into THAT version's deps (read from the registry, no
/// download); gathers every version reached per module; then settles each module to
/// the MAX within each compatibility set. Returns the selected exact versions
/// per module, retaining separate versions for incompatible sets. Local
/// deps are the caller's concern (they override registry requirements) and are
/// skipped here.
pub fn mvs_resolve(
  root_deps : Array[@config.Dependency],
  registry : &Registry,
  skip? : Set[String] = Set([]),
  local_reqs? : Map[String, Array[(String, String)]] = {},
) -> Map[String, Array[String]] raise ResolveError {
  let t_total = @unix.now_ns()
  // name -> (version -> dependants) for every min-satisfying version reached.
  let gathered : Map[String, Map[String, Array[String]]] = Map([])
  let visited : Set[String] = Set([]) // `name@version` already expanded
  let working : Array[(String, String, String)] = [] // (name, req, dependant)
  let mut requirements = 0
  let mut registry_calls = 0
  let mut registry_ms = 0L
  for d in root_deps {
    match d {
      Registry(name~, version~) => working.push((name, version, "<root>"))
      Local(..) => ()
    }
  }
  while working.length() > 0 {
    requirements += 1
    let (name, req, dependant) = working.pop().unwrap()
    // A locally-overridden module is resolved outside MVS (its source + deps come
    // from disk), so we neither select a registry version nor descend into it here.
    // But we RECORD the requirement placed on it, so the caller can warn if the local
    // copy's version doesn't actually satisfy what a registry dependant asked for.
    if skip.contains(name) {
      match local_reqs.get(name) {
        Some(a) => a.push((req, dependant))
        None => local_reqs[name] = [(req, dependant)]
      }
      continue
    }
    let t_lookup = @unix.now_ns()
    let all_versions = registry.all_versions_of(name)
    registry_calls += 1
    registry_ms += mvs_timing_ms(t_lookup)
    let all = match all_versions {
      Some(m) => m
      None => raise ModuleMissing(name~, dependant~)
    }
    let avail = all.keys().to_array()
    let version = match select_min_version_satisfying(req, avail) {
      Some(v) => v
      None => raise NoSatisfiedVersion(name~, dependant~, required=req)
    }
    // Gather (with the dependant, for conflict reporting).
    let by_ver = match gathered.get(name) {
      Some(m) => m
      None => {
        let m : Map[String, Array[String]] = Map([])
        gathered[name] = m
        m
      }
    }
    match by_ver.get(version) {
      Some(ds) => ds.push(dependant)
      None => by_ver[version] = [dependant]
    }
    // Expand this concrete version's transitive deps exactly once.
    let key = "\{name}@\{version}"
    if visited.contains(key) {
      continue
    }
    visited.add(key)
    for td in all.get(version).unwrap() {
      match td {
        Registry(name=dn, version=dv) => working.push((dn, dv, name))
        Local(..) => ()
      }
    }
  }
  mvs_timing_log_ms(
    "resolve.mvs.registry_lookup_sum calls=\{registry_calls}",
    registry_ms,
  )
  // Settle: per module, group gathered versions by compatibility set and keep
  // the maximum in each set. Distinct sets retain distinct build identities.
  let selected : Map[String, Array[String]] = Map([])
  for name, by_ver in gathered {
    let sets : Map[Int, (String, SemVer, Array[String])] = Map([])
    for version, deps in by_ver {
      let sv = parse_semver(version)
      let k = sv.compat_key()
      match sets.get(k) {
        Some((raw, csv, dependants)) => {
          for d in deps {
            dependants.push(d)
          }
          if sv.cmp(csv) > 0 {
            sets[k] = (version, sv, dependants)
          } else {
            sets[k] = (raw, csv, dependants)
          }
        }
        None => sets[k] = (version, sv, [..deps])
      }
    }
    let versions : Array[String] = []
    for _, triple in sets {
      let (raw, _, _) = triple
      versions.push(raw)
    }
    versions.sort_by(fn(a, b) { parse_semver(a).cmp(parse_semver(b)) })
    selected[name] = versions
  }
  mvs_timing_log(
    "resolve.mvs.detail requirements=\{requirements} visited=\{visited.length()} gathered=\{gathered.length()} selected=\{selected.length()}",
    t_total,
  )
  selected
}

///|
/// Pick the settled version belonging to a requirement's compatibility set.
pub fn select_for_requirement(
  selected : Map[String, Array[String]],
  name : String,
  required : String,
) -> String? {
  let versions = match selected.get(name) { Some(v) => v; None => return None }
  for version in versions {
    if mvs_requirement_matches(parse_semver(required), parse_semver(version)) {
      return Some(version)
    }
  }
  None
}
