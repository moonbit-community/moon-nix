extern "C" fn ffi_value() -> Int = "moon_nix_value"
pub fn value() -> Int { ffi_value() }
