///|
/// A pinned, unpacked registry index. The caller supplies its Nix-store path.
pub struct Index {
  root : String
  cache : Map[String, Map[String, Array[@config.Dependency]]?]
  checksums : Map[String, Map[String, String]]
}

///|
pub fn Index::new(root : String) -> Index {
  { root, cache: Map([]), checksums: Map([]) }
}

///|
pub fn Index::checksum(self : Index, name : String, version : String) -> String? {
  match self.checksums.get(name) {
    Some(by_version) => by_version.get(version)
    None => None
  }
}

///|
pub fn Index::dependencies(
  self : Index,
  name : String,
  version : String,
) -> Array[@config.Dependency]? raise ResolveError {
  match self.all_versions_of(name) {
    Some(versions) => versions.get(version)
    None => None
  }
}

///|
pub extend Index with Registry::{all_versions_of}

///|
pub impl Registry for Index with fn all_versions_of(self, name) {
  match self.cache.get(name) {
    Some(value) => return value
    None => ()
  }
  let file = self.root + "/user/" + name + ".index"
  if !@os.exists(file) {
    self.cache[name] = None
    return None
  }
  let versions : Map[String, Array[@config.Dependency]] = Map([])
  let checksums : Map[String, String] = Map([])
  for line in @os.read_file(file).split("\n") {
    let entry = line.trim().to_owned()
    if entry == "" { continue }
    let fields = match @parse.parse_json_manifest(entry) {
      Some(value) => value
      None => raise FetchFailed(url=file, detail="invalid JSON index record")
    }
    let mod = @config.decode_mod(fields) catch {
      _ => raise FetchFailed(url=file, detail="invalid module manifest")
    }
    if mod.name != name {
      raise FetchFailed(url=file, detail="index record has wrong module name")
    }
    let version = match mod.version {
      Some(value) => value
      None => raise FetchFailed(url=file, detail="index record has no version")
    }
    versions[version] = mod.deps
    for field in fields {
      let (key, value) = field
      if key == "checksum" {
        match value {
          @config.Str(hash) => checksums[version] = hash
          _ => raise FetchFailed(url=file, detail="invalid checksum")
        }
      }
    }
  }
  self.cache[name] = Some(versions)
  self.checksums[name] = checksums
  Some(versions)
}
