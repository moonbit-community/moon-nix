// Minimal Version Selection (MVS):
//   - Compatibility sets: majors `< 2` are ONE set (0.x and 1.x are mutually
//     compatible); each major `>= 2` is its own set.
//   - Each declared version is a lower bound. Select the minimum available
//     version satisfying each requirement, then the maximum reached per set.
//   - A module required across MORE THAN ONE compatibility set is a genuine
//     conflict, so we ERROR.

///|
/// A parsed `major.minor.patch` .
priv struct SemVer {
  major : Int
  minor : Int
  patch : Int
}

///|
/// Parse `1.2.3` into a `SemVer` for ordering, dropping the pre-release (`-…`) and
/// build-metadata (`+…`) suffixes .
fn parse_semver(s : String) -> SemVer {
  let core = match s.split_once("-") {
    Some((a, _)) => a.to_owned()
    None => s
  }
  let core = match core.split_once("+") {
    Some((a, _)) => a.to_owned()
    None => core
  }
  if core == "" {
    return { major: 0, minor: 0, patch: 0 } // version-less local module
  }
  let nums : Array[Int] = []
  for part in core.split(".") {
    nums.push(
      @string.parse_int(part.to_owned()) catch {
        _ => abort("parse_semver: non-numeric version component in `\{s}`")
      },
    )
  }
  guard nums.length() == 3 else {
    abort("parse_semver: expected `major.minor.patch`, got `\{s}`")
  }
  { major: nums[0], minor: nums[1], patch: nums[2] }
}

///|
/// The compatibility-set key: the same pkg whose majors below 2 collapse to one set; each major
/// `>= 2` is its own set.
fn SemVer::compat_key(self : SemVer) -> Int {
  if self.major < 2 {
    0
  } else {
    self.major
  }
}

///|
fn SemVer::cmp(self : SemVer, other : SemVer) -> Int {
  if self.major != other.major {
    self.major - other.major
  } else if self.minor != other.minor {
    self.minor - other.minor
  } else {
    self.patch - other.patch
  }
}
