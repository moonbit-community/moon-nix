// JSON manifest support: though deprecated most PUBLISHED modules in the ecosystem still only ship
// `moon.mod.json` / `moon.pkg.json` (JSON).

///|
/// Lower a stdlib `Json` value into mymoon's `@config.Value`.
fn json_to_value(j : Json) -> @config.Value {
  match j {
    Object(m) => {
      let out : Map[String, @config.Value] = Map([])
      for k, v in m {
        out[k] = json_to_value(v)
      }
      Object(out)
    }
    Array(a) => {
      let out : Array[@config.Value] = []
      for v in a {
        out.push(json_to_value(v))
      }
      Array(out)
    }
    String(s) => Str(s)
    Number(n, ..) => Int(n.to_int())
    True => Bool(true)
    False => Bool(false)
    Null => Str("")
  }
}

///|
/// Parse a JSON manifest (moon.mod.json / moon.pkg.json) into the same ordered
/// `(key, value)` entries the DSL parser produces.
pub fn parse_json_manifest(input : String) -> Array[(String, @config.Value)]? {
  try @json.parse(input) catch {
    _ => None
  } noraise {
    Object(m) => {
      let out : Array[(String, @config.Value)] = []
      for k, v in m {
        out.push((k, json_to_value(v)))
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// Load a module manifest from `dir`: DSL `moon.mod` first, else JSON
/// `moon.mod.json`. `None` if neither parses.
pub fn load_mod(dir : String) -> Array[(String, @config.Value)]? {
  let dsl = dir + "/moon.mod"
  if @os.exists(dsl) {
    return parse_mod(@os.read_file(dsl))
  }
  let json = dir + "/moon.mod.json"
  if @os.exists(json) {
    return parse_json_manifest(@os.read_file(json))
  }
  None
}

///|
/// Load a package manifest from `dir`: DSL `moon.pkg` first, else JSON
/// `moon.pkg.json`. `None` if neither parses.
pub fn load_pkg(dir : String) -> Array[(String, @config.Value)]? {
  let dsl = dir + "/moon.pkg"
  if @os.exists(dsl) {
    return parse_pkg(@os.read_file(dsl))
  }
  let json = dir + "/moon.pkg.json"
  if @os.exists(json) {
    return parse_json_manifest(@os.read_file(json))
  }
  None
}

///|
/// Whether `dir` holds a module manifest (DSL or JSON) — nested-module detection.
pub fn has_mod(dir : String) -> Bool {
  @os.exists(dir + "/moon.mod") || @os.exists(dir + "/moon.mod.json")
}

///|
/// Whether `dir` holds a package manifest (DSL or JSON).
pub fn has_pkg(dir : String) -> Bool {
  @os.exists(dir + "/moon.pkg") || @os.exists(dir + "/moon.pkg.json")
}
