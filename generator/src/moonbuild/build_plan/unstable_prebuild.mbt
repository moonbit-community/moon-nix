// Compatibility shim for the official `__moonbit_unstable_prebuild`: a module-level
// manifest field naming an opaque SCRIPT that moon runs before building. The script
// is dispatched to an interpreter by extension (`.py` → python3, else node), fed a
// JSON payload on stdin (`{ "env": {...} }`), and is expected to print a JSON result
// (`{ "vars": {...}, "link_configs": [ {"package": "...", "link_flags": "..."} ] }`)
// on stdout. We consume `link_configs[].link_flags` into the named package's native
// link; the script's arbitrary SIDE EFFECTS (codegen, downloads) happen as it runs.
//
// It runs at PLAN time, every build — the script is opaque, so its inputs can't be
// tracked and caching its output would be unsound (it may read other files / system
// state / the network). Downstream compiles + links still cache normally on their
// action identities, so an unchanged result re-triggers nothing. This exists only
// to run existing projects.

///|
/// Run every distinct `--moonbit-unstable-prebuild` script across the packages in
/// `order` (once per script — a multi-package module declares it on all its packages
/// but the script runs once), and merge their `link_configs` into one
/// `package fqn → final-link words` map. Empty when no module in the closure declares
/// a prebuild.
fn collect_prebuild_link_map(
  packages : @model.BuildDiscovery,
  order : Array[@pkg_solve.BuildTarget],
) -> Map[String, Array[String]] raise BuildPlanError {
  let map : Map[String, Array[String]] = Map([])
  let seen_script : Set[String] = Set([])
  let seen_pkg : Set[@model.PackageId] = Set([])
  for bt in order {
    if seen_pkg.contains(bt.pkg) {
      continue
    }
    seen_pkg.add(bt.pkg)
    let pkg = packages.get_package(bt.pkg)
    guard pkg.module_prebuild is Some(script) else { continue }
    if seen_script.contains(script) {
      continue
    }
    seen_script.add(script)
    for k, v in run_unstable_prebuild(script, pkg.module_root) {
      map[k] = v
    }
  }
  map
}

///|
/// Run a module's prebuild `script` (absolute path) with cwd = `module_root`, and
/// return the `link_configs` it reports as a map: package fqn → final-link words.
/// Raises [`PrebuildFailed`] on a non-zero exit or non-JSON output.
fn run_unstable_prebuild(
  script : String,
  module_root : String,
) -> Map[String, Array[String]] raise BuildPlanError {
  // Dispatch the interpreter by script extension (overridable for hermetic envs).
  let interp = if script.has_suffix(".py") {
    @os.getenv_or("MOON_PREBUILD_PYTHON", "python3")
  } else {
    // `.js` / `.mjs` / `.cjs` (and anything else) → node, like the official runner.
    @os.getenv_or("MOON_PREBUILD_NODE", "node")
  }
  // The JSON payload on the child's stdin. We keep `env` empty: the child inherits
  // our process environment, and the real scripts read `payload.env[x] ?? process.env[x]`,
  // so the inherited env covers MOON_CC / PATH / OS without us enumerating it. Writing
  // it to a file (rather than inheriting our stdin) is what stops a script that reads
  // fd 0 from blocking on an interactive TTY.
  let tmp = @os.getenv_or("TMPDIR", "/tmp") + "/mymoon-prebuild"
  @os.mkdir_p(tmp)
  let payload_path = "\{tmp}/\{@os.getpid()}-\{@os.now_ns()}.json"
  @os.write_file(payload_path, "{\"env\":{}}")
  // Run with cwd = module root (scripts like openssl's build.py use cwd-relative
  // paths). No per-child cwd primitive, so chdir around the call (plan is single-threaded).
  let saved = @os.cwd()
  @os.chdir(module_root) |> ignore
  let (code, out, err) = @os.capture_argv_stdin([interp, script], payload_path)
  @os.chdir(saved) |> ignore
  @os.remove_all(payload_path)
  if code != 0 {
    raise PrebuildFailed(
      script~,
      message=if code == -1 && err.is_empty() {
        "prebuild interpreter `\{interp}` not found on PATH"
      } else {
        err.trim().to_owned()
      },
    )
  }
  parse_link_configs(out, script)
}

///|
/// Parse the script's stdout JSON, returning `package → link-flag words` from its
/// `link_configs`. Empty output / missing `link_configs` is fine (a prebuild may
/// exist purely for its side effects). Raises only on output that isn't valid JSON.
fn parse_link_configs(
  out : String,
  script : String,
) -> Map[String, Array[String]] raise BuildPlanError {
  let result : Map[String, Array[String]] = Map([])
  // A prebuild may legitimately print nothing (side-effects only).
  if out.trim().is_empty() {
    return result
  }
  let j = @json.parse(out) catch {
    _ =>
      raise PrebuildFailed(
        script~,
        message="prebuild stdout is not valid JSON: \{out}",
      )
  }
  guard j is Object(top) else { return result }
  guard top.get("link_configs") is Some(Array(items)) else { return result }
  for it in items {
    guard it is Object(o) else { continue }
    let pkg = match o.get("package") {
      Some(String(p)) => p
      _ => continue
    }
    let flags = match o.get("link_flags") {
      Some(String(f)) => f
      _ => ""
    }
    let words : Array[String] = []
    for w in flags.split(" ") {
      let w = w.trim().to_owned()
      if !w.is_empty() {
        words.push(w)
      }
    }
    result[pkg] = words
  }
  result
}
