extern "C" fn bonus() -> Int = "moon_nix_bonus"
fn main { println(@lib.value() + bonus()) }
