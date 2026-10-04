extern "C" fn bonus() -> Int = "moon2nix_bonus"
fn main { println(@lib.value() + bonus()) }
