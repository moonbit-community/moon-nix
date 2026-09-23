///|
/// A "lenient" DSL value: the untyped, shape-faithful result of parsing, before
/// any schema is applied.
///
/// This is our own small ADT, deliberately NOT the builtin `Json`: the DSL can
/// only ever produce these five shapes. In particular integers are a native
/// `Int` (no `Double`/repr dance), and there is no `Null` or float, because the
/// grammar cannot express them.
///
/// Strong types (`MoonMod` / `MoonPkg`) are produced *later* by decoding a
/// `Value`. That decode step is the single boundary where untyped shape becomes
/// a trusted, typed domain model.
pub(all) enum Value {
  Bool(Bool)
  Int(Int)
  Str(String)
  Array(Array[Value])
  Object(Map[String, Value])
} derive(Debug)

///|
pub extend Value with @moonbitlang/core/debug.Debug::{to_repr}
