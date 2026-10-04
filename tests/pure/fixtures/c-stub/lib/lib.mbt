extern "C" fn ffi_value() -> Int = "moon2nix_value"
pub fn value() -> Int { ffi_value() }
