///|
struct ResolvedPlanSources {
  metadata : Json
  /// importer `name@version` -> imported module name -> selected version
  edges : Map[String, Map[String, String]]
}

///|
fn add_module_edges(
  edges : Map[String, Map[String, String]],
  selected : Map[String, Array[String]],
  key : String,
  deps : Array[@config.Dependency],
) -> Unit {
  let targets : Map[String, String] = Map([])
  for dep in deps {
    match dep {
      @config.Registry(name~, version~) => {
        let chosen = match @mvs.select_for_requirement(selected, name, version) {
          Some(value) => value
          None => {
            fail("no settled version of " + name + " satisfies " + version)
            return
          }
        }
        targets[name] = chosen
      }
      @config.Local(..) => ()
    }
  }
  edges[key] = targets
}

///|
/// Resolve external modules against an explicit, pinned registry index and check
/// every supplied source root. Keep an edge-specific version choice so distinct
/// compatibility groups of the same module can coexist.
fn resolve_plan_sources(
  root : String,
  dirs : Array[String],
  index_dir : String,
) -> ResolvedPlanSources {
  let entries = match @parse.load_mod(root) {
    Some(value) => value
    None => {
      fail("cannot read root moon.mod")
      return { metadata: Json::null(), edges: Map([]) }
    }
  }
  let root_mod = @config.decode_mod(entries) catch {
    _ => {
      fail("invalid root moon.mod")
      return { metadata: Json::null(), edges: Map([]) }
    }
  }
  let index = @mvs.Index::new(index_dir)
  let selected = @mvs.mvs_resolve(root_mod.deps, index) catch {
    error => {
      fail(@mvs.describe_error(error))
      return { metadata: Json::null(), edges: Map([]) }
    }
  }
  let supplied : Map[String, Int] = Map([])
  for i in 1..<dirs.length() {
    let entries = match @parse.load_mod(dirs[i]) {
      Some(value) => value
      None => {
        fail("cannot read dependency moon.mod: " + dirs[i])
        return { metadata: Json::null(), edges: Map([]) }
      }
    }
    let mod = @config.decode_mod(entries) catch {
      _ => {
        fail("invalid dependency moon.mod: " + dirs[i])
        return { metadata: Json::null(), edges: Map([]) }
      }
    }
    let version = match mod.version { Some(v) => v; None => "" }
    supplied[mod.name + "@" + version] = i
  }
  let out : Map[String, Json] = Map([])
  let edges : Map[String, Map[String, String]] = Map([])
  let root_version = match root_mod.version { Some(v) => v; None => "" }
  add_module_edges(
    edges, selected, root_mod.name + "@" + root_version, root_mod.deps,
  )
  for name, versions in selected {
    for version in versions {
      let key = name + "@" + version
      let i = match supplied.get(key) {
        Some(value) => value
        None => {
          for provided, _ in supplied {
            if provided.has_prefix(name + "@") {
              fail(
                "source root for " + name + " is " +
                provided[name.length() + 1:].to_owned() +
                ", but MVS selected " + version,
              )
              return { metadata: Json::null(), edges: Map([]) }
            }
          }
          fail("missing source root for resolved module " + key)
          return { metadata: Json::null(), edges: Map([]) }
        }
      }
      let checksum = match index.checksum(name, version) {
        Some(value) => value
        None => {
          fail("missing checksum for " + key)
          return { metadata: Json::null(), edges: Map([]) }
        }
      }
      let deps = index.dependencies(name, version) catch {
        error => {
          fail(@mvs.describe_error(error))
          return { metadata: Json::null(), edges: Map([]) }
        }
      }
      add_module_edges(edges, selected, key, deps.unwrap_or([]))
      out[key] = {
        "version": version.to_json(),
        "checksum": checksum.to_json(),
        "sourceIndex": i.to_json(),
      }
    }
  }
  { metadata: out.to_json(), edges }
}
