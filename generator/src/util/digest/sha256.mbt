// SHA-256, provided by the semi-official `moonbitlang/x/crypto` (chosen over a
// hand-rolled implementation now that a maintained one exists). This thin
// wrapper is the ONLY place that touches the crypto library, so the rest of
// the codebase (digest, nar) is insulated — swapping providers touches only this
// file. SHA-256 is the right primitive for nix-store / Bazel-REv2 alignment.

///|
/// SHA-256 of `data`, as 64 lowercase hex chars.
pub fn sha256_hex(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}
