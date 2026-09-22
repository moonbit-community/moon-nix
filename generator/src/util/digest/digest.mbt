// Content fingerprint. Pure computation. Backed by XXH64:
// fast, high-quality, non-cryptographic — this is the **machine-local** content key
// (build CAS / action / stat / discovery caches). A local cache has no adversary, so
// cryptographic collision resistance buys nothing; XXH64 is far faster than SHA-256,
// and over a 64-bit space random collisions are negligible for a per-user, clearable
// cache. Integrity across trust boundaries (a dependency's nar-sha256) uses SHA-256 (see
// sha256.mbt / nar.mbt), not this.

///|
pub(all) struct Digest(String)

///|
pub fn Digest::to_string(self : Digest) -> String {
  self.0
}

///|
pub fn from_bytes(b : Bytes) -> Digest {
  Digest(@xxh64.to_hex(@xxh64.xxh64(b)))
}

///|
pub fn from_string(s : String) -> Digest {
  from_bytes(@utf8.encode(s[:]))
}

// Combine several parts into one fingerprint (used for action_digest)

///|
pub fn combine(parts : Array[String]) -> Digest {
  let mut s = ""
  for p in parts {
    s = s + p + "\n"
  }
  from_string(s)
}
