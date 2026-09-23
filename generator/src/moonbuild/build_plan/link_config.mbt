// Lowering of the manifest `link` block (`@config.LinkConfig`) into the plan:
// which packages are linkable, and what backend-specific settings their
// `link-core` / native cc actions carry.

///|
pub fn is_linkable(pkg : @model.Package, backend : Backend) -> Bool {
  pkg.is_main ||
  pkg.is_linked ||
  (match pkg.link {
    Some(l) => l.need_link(backend.name())
    None => false
  })
}

///|
/// Split a manifest flag STRING into argv words (moon shlex-splits; whitespace
/// splitting covers the manifest shapes in the wild — no quoting support).
fn split_words(s : String?) -> Array[String] {
  match s {
    Some(s) =>
      s
      .split(" ")
      .filter_map(w => if w.is_empty() { None } else { Some(w.to_owned()) })
      .to_array()
    None => []
  }
}

///|
/// The package's `link.<backend>.exports` for the ACTIVE backend (native and
/// llvm share `link.native`, like moon). Empty when unset.
fn link_exports(pkg : @model.Package, backend : Backend) -> Array[String] {
  match pkg.link {
    Some(l) =>
      match backend {
        Wasm =>
          match l.wasm {
            Some(w) => w.exports
            None => []
          }
        WasmGc =>
          match l.wasm_gc {
            Some(w) => w.exports
            None => []
          }
        Js =>
          match l.js {
            Some(j) => j.exports
            None => []
          }
        Native(_) | Llvm(_) =>
          match l.native {
            Some(n) => n.exports
            None => []
          }
      }
    None => []
  }
}

///|
/// `-js-format` is emitted iff the manifest HAS a `link.js` object (its absence
/// leaves moonc's own default in charge) — the decoded `format` already defaults
/// to `"esm"`. Only meaningful on the js backend.
fn link_js_format(pkg : @model.Package, backend : Backend) -> String? {
  guard backend is Js else { return None }
  match pkg.link {
    Some(l) =>
      match l.js {
        Some(j) => Some(j.format)
        None => None
      }
    None => None
  }
}

///|
/// The wasm/wasm-gc link settings for the ACTIVE backend, lowered to the
/// path-free [`@core.WasmLinkOpts`]. `None` on other backends or when the
/// manifest has no matching block.
fn link_wasm_opts(
  pkg : @model.Package,
  backend : Backend,
) -> @core.WasmLinkOpts? {
  guard pkg.link is Some(l) else { return None }
  match backend {
    Wasm =>
      match l.wasm {
        Some(w) =>
          Some(@core.WasmLinkOpts::{
            export_memory_name: w.export_memory_name,
            import_memory: w.import_memory.map(fn(im) {
              (im.module_name, im.name)
            }),
            memory_limits: w.memory_limits.map(fn(ml) { (ml.min, ml.max) }),
            shared_memory: w.shared_memory,
            heap_start_address: w.heap_start_address,
            use_js_builtin_string: false,
            imported_string_constants: None,
            flags: w.flags,
          })
        None => None
      }
    WasmGc =>
      match l.wasm_gc {
        Some(w) =>
          Some(@core.WasmLinkOpts::{
            export_memory_name: w.export_memory_name,
            import_memory: w.import_memory.map(fn(im) {
              (im.module_name, im.name)
            }),
            memory_limits: w.memory_limits.map(fn(ml) { (ml.min, ml.max) }),
            shared_memory: w.shared_memory,
            heap_start_address: None, // linear-wasm only, never wasm-gc
            use_js_builtin_string: w.use_js_builtin_string,
            imported_string_constants: w.imported_string_constants,
            flags: w.flags,
          })
        None => None
      }
    _ => None
  }
}

///|
/// The package's `link.native` block, if any — the cc / stub-cc override source.
fn native_link_of(pkg : @model.Package) -> @config.NativeLinkConfig? {
  match pkg.link {
    Some(l) => l.native
    None => None
  }
}

///|
/// The package's effective `link.native`, currently just the manifest's regular
/// `link.native` block.
fn effective_native_link(pkg : @model.Package) -> @config.NativeLinkConfig? {
  native_link_of(pkg)
}
