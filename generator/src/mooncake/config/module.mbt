///|
/// The typed, validated form of a `moon.mod` manifest. It is produced by
/// `decode_mod` from the untyped `Dsl` (the `[(String, Value)]` a parser emits).
/// That decode call is the single boundary where untyped data becomes a trusted,
/// typed value: after it, `mod.name` is just a `String`, `mod.keywords` an
/// `Array[String]` — the compiler guards every later use.
pub(all) struct MoonMod {
  name : String //                required
  version : String? //            optional
  keywords : Array[String] //     optional, defaults to []
  deps : Array[Dependency] //     optional, defaults to []
  source : String //              options(source: "src"); "" = scan from module root
  // `compile-flags` / `link-flags`: extra moonc args appended MODULE-WIDE — the
  // former to every `build-package`/`check`, the latter to `link-core` (and the
  // native `cc` link). e.g. `["-O2"]`, `["-D", "FOO"]`. Default [].
  compile_flags : Array[String]
  link_flags : Array[String]
  // `supported-targets` — module-wide backend set; each package's effective set is
  // its own `supported-targets` intersected with this. `None` = every backend.
  supported_targets : Array[String]?
  // `rule = [{ name, command }, …]` — named pre-build templates available to every
  // package in this module (looked up AFTER a package's own `local_rules`).
  rules : Array[ModRule]
  // Module-wide `warnings` / `alert-list`. Each package's EFFECTIVE list is this
  // CONCATENATED with the package's own (module first), mirroring moon's `cat_opt`.
  warn_list : String?
  alert_list : String?
  // `preferred-target` — the default backend for this workspace, used when the CLI
  // is invoked WITHOUT an explicit `--target`. `None` = no preference (the
  // command's built-in default applies). A backend name (wasm-gc/native/js/wasm).
  preferred_target : String?
  // `include` / `exclude`: gitignore-style globs scoping which files `moon package`
  // ships. If `include` is non-empty it WINS (exclude ignored) and the bundle is
  // exactly the matching files (+ the manifest); otherwise the default is every
  // file in the module tree minus `exclude` matches. Both default to [].
  includes : Array[String]
  excludes : Array[String]
  // `--moonbit-unstable-prebuild` — an opaque prebuild SCRIPT (path relative to the
  // module root) that moon runs before building: `.js`/`.mjs` via node, `.py` via
  // python3. It speaks a JSON stdin→stdout protocol (`{env}` in, `{vars, link_configs}`
  // out) and may have arbitrary side effects (codegen, downloads). `None` = no script.
  // Run every build (it is opaque, so its inputs can't be tracked — caching it would
  // be unsound); the declarative features are the cacheable alternative.
  unstable_prebuild : String?
  // `bin-deps` — dependency modules built into executable build-tools, invoked from
  // `pre-build` commands via `$mooncake_bin`. Non-transitive (root module only).
  // Defaults to [].
  bin_deps : Array[BinDep]
} derive(Debug)

///|
pub extend MoonMod with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A declared module dependency.
///   - `Registry` — the ONLY form a `moon.mod` can declare, written as
///     `"name@1.2.3"` in the `import { ... }` block (exact version).
///   - `Local` — a local-source module, NOT written in any manifest: it is injected
///     by `moon.work` for each workspace member (see `workspace_local_deps`), which
///     is how multiple modules are developed together. A non-version `deps` spec (a
///     `path` local, or any other) is rejected at decode time (see [`as_dependency`]).
pub(all) enum Dependency {
  Registry(name~ : String, version~ : String)
  Local(name~ : String, path~ : String)
} derive(Debug)

///|
pub extend Dependency with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A `bin-deps` entry: a dependency module whose `main` (or `bin-pkg`-named)
/// packages are compiled into stand-alone EXECUTABLES used as build-time tools
/// (invoked from a `pre-build` command via the `$mooncake_bin` placeholder). A
/// bin-dep is NOT linked into your code and is NOT transitive — only the root
/// module's bin-deps are built. Mirrors rust moon's `BinaryDependencyInfo`.
pub(all) struct BinDep {
  name : String //              the dependency module name
  source : BinDepSource //      where its source comes from (local path / registry)
  // `bin-pkg` — which packages of the dep module to build as executables. Empty
  // means "every `is-main`/linkable package", matching `moon tool build-binary-dep
  // --all-pkgs`. Each entry is a package fqn within the dep module.
  bin_pkg : Array[String]
} derive(Debug)

///|
pub extend BinDep with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The source of a `bin-deps` entry. Unlike a regular `deps` entry (registry
/// only, locals come via `moon.work`), a bin-dep MAY name a local `path`: a
/// codegen tool living in a sibling directory is the common case, and there is no
/// workspace mechanism for tools.
pub(all) enum BinDepSource {
  Local(path~ : String)
  Registry(version~ : String)
} derive(Debug)

///|
pub extend BinDepSource with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Raised by `decode_mod` when a required field is missing or a value has the
/// wrong shape.
pub suberror DecodeError {
  MissingField(String)
  WrongType(field~ : String, expected~ : String)
  // Two manifest keys that may not coexist (e.g. `dev_build` + `pre-build`).
  Conflict(String)
}

///|
fn as_string(field : String, v : Value) -> String raise DecodeError {
  match v {
    Str(s) => s
    _ => raise WrongType(field~, expected="string")
  }
}

///|
/// Validate (and return) a `major.minor.patch` version string. The three core
/// components must each be a non-empty run of digits; an optional pre-release
/// (`-…`) / build-metadata (`+…`) suffix is allowed but not otherwise checked.
///
/// Mirrors rust moon, which strict-parses every manifest version through the
/// `semver` crate and errors on malformed input — so a typo like `1.2` or `abc`
/// is rejected here, at the manifest boundary, instead of being silently coerced
/// to `0` further down in MVS ([`@mooncake.parse_semver`] now assumes valid input).
fn validate_version(field : String, s : String) -> String raise DecodeError {
  // Core triple = everything before the first `-` (pre-release) then `+` (build).
  let core = match s.split_once("-") {
    Some((a, _)) => a.to_owned()
    None => s
  }
  let core = match core.split_once("+") {
    Some((a, _)) => a.to_owned()
    None => core
  }
  let parts : Array[String] = []
  for p in core.split(".") {
    parts.push(p.to_owned())
  }
  guard parts.length() == 3 else {
    raise WrongType(field~, expected="semver version `major.minor.patch`")
  }
  for p in parts {
    guard p != "" && p.iter().all(c => c.is_ascii_digit()) else {
      raise WrongType(field~, expected="semver version `major.minor.patch`")
    }
  }
  s
}

///|
fn as_version(field : String, v : Value) -> String raise DecodeError {
  validate_version(field, as_string(field, v))
}

///|
fn as_string_array(
  field : String,
  v : Value,
) -> Array[String] raise DecodeError {
  match v {
    Array(items) => items.map(it => as_string(field, it))
    _ => raise WrongType(field~, expected="array of strings")
  }
}

///|
/// The typed, validated form of a `moon.pkg` manifest. Unlike `moon.mod`, a
/// `moon.pkg` uses block forms — `import { ... }` and `options(...)` — which the
/// parser lowers to an `"import"` array and an `"options"` object; `decode_pkg`
/// turns those into typed fields.
pub(all) struct ImportSpec {
  /// Imported package_name path, verbatim from the manifest.
  path : String
  /// Explicit import alias (`as` / JSON `"alias"`); `None` = default (last path segment).
  import_alias : String?
  /// `"sub-package": true` — import the dependency's SUB-PACKAGE (its `_sub.mi`)
  /// rather than its main `Source` interface. Defaults to `false`.
  sub_package : Bool
} derive(ToJson, FromJson)

///|
pub extend ImportSpec with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend ImportSpec with ToJson::{to_json}

///|
/// A conditional-compilation expression, from a `targets` entry. A file is
/// compiled for a given backend/optlevel iff its expression evaluates true.
/// Mirrors moon's cond-expr: an atom (`"js"`, `"release"`, …) or a logic node.
pub(all) enum CondExpr {
  Target(String) //          a backend atom: wasm / wasm-gc / js / native / llvm
  OptLevel(String) //        an optlevel atom: debug / release
  And(Array[CondExpr])
  Or(Array[CondExpr])
  Not(Array[CondExpr]) //    true iff NONE of the sub-exprs hold (moon's `not`)
} derive(ToJson, FromJson)

///|
pub extend CondExpr with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend CondExpr with ToJson::{to_json}

///|
/// Evaluate a cond-expr against the active `target` backend and `opt` level
/// ("debug"/"release"). A `Target` atom matches the backend, an `OptLevel` atom
/// the level; `Not` is "none of".
pub fn cond_eval(e : CondExpr, target : String, opt : String) -> Bool {
  match e {
    Target(b) => b == target
    OptLevel(o) => o == opt
    And(es) => es.all(x => cond_eval(x, target, opt))
    Or(es) => es.any(x => cond_eval(x, target, opt))
    Not(es) => !es.any(x => cond_eval(x, target, opt))
  }
}

///|
/// Parse one cond-expr value: a bare atom string, or an array whose first
/// element is `and`/`or`/`not` (logic) — otherwise the whole array is an
/// implicit `or` over atoms.
fn parse_cond_expr(v : Value) -> CondExpr raise DecodeError {
  match v {
    Str(s) => parse_cond_atom(s)
    Array(items) => {
      guard items.length() > 0 else {
        raise WrongType(field="targets", expected="non-empty condition array")
      }
      let head = match items[0] {
        Str(s) => s
        _ => ""
      }
      if head == "and" || head == "or" || head == "not" {
        let subs : Array[CondExpr] = []
        for i in 1..<items.length() {
          subs.push(parse_cond_expr(items[i]))
        }
        match head {
          "and" => And(subs)
          "or" => Or(subs)
          _ => Not(subs)
        }
      } else {
        // first element is itself an atom → implicit `or` over all elements
        let subs : Array[CondExpr] = []
        for it in items {
          subs.push(parse_cond_expr(it))
        }
        Or(subs)
      }
    }
    _ => raise WrongType(field="targets", expected="string or array")
  }
}

///|
fn parse_cond_atom(s : String) -> CondExpr raise DecodeError {
  match s {
    "debug" | "release" => OptLevel(s)
    "wasm" | "wasm-gc" | "js" | "native" | "llvm" => Target(s)
    _ => raise WrongType(field="targets", expected="known target/optlevel atom")
  }
}

///|
pub(all) struct MoonPkg {
  imports : Array[ImportSpec] // import path + optional explicit import_alias, default []
  // Test-only imports, ADDITIONAL to `imports`: `wbtest_imports` are available to
  // whitebox tests (`_wbtest.mbt`, from `import {} for "wbtest"`), `test_imports`
  // to blackbox tests (`_test.mbt`, from `import {} for "test"`). The legacy
  // literal `test-import`/`wbtest-import` keys (deprecated in moon) are not
  // accepted — only the `for "…"` block. Default [].
  wbtest_imports : Array[ImportSpec]
  test_imports : Array[ImportSpec]
  // Backend-conditional imports (`import {} for "<backend>"`), keyed by backend
  // name ("native"/"wasm-gc"/"wasm"/"js"/"llvm"). ADDITIONAL to `imports` when
  // building for that backend. Default {}.
  cond_imports : Map[String, Array[ImportSpec]]
  is_main : Bool //              options("is-main": ...), defaults to false
  native_stub : Array[String] // options("native-stub": [...]), defaults to []
  // `import-moonbit-h`: pre-translate the toolchain's `moonbit.h` to a Zig module
  // via `zig translate-c`, so a `.zig` native stub can `@import("moonbit")` its
  // macros/decls. Pairs with `native-stub`, not `link`. `false` by default; only the
  // rare zig stub that needs `moonbit.h` MACROS sets it (the common Bytes-only stub
  // hand-writes `extern` decls instead). Was once a `zig-translate-headers` list, but
  // `translate-c` only ever resolves against the toolchain `include_dir` (no package
  // include path), whose sole useful header is `moonbit.h` — so the list could never
  // hold anything else, and it collapsed to this flag.
  needs_translate_moonbit_h : Bool
  prebuild : Array[PrebuildRule] // options("pre-build": [...]), defaults to []
  // options("targets": { "<file>": <cond-expr> }) — per-file conditional
  // compilation; a file absent here compiles for every target.
  targets : Map[String, CondExpr]
  // `virtual = { "has-default": <bool> }` — this package is a virtual package: it
  // declares an INTERFACE (a hand-written `.mbti`) with no implementation (or only
  // a default one). `None` = an ordinary package.
  virtual_pkg : VirtualConfig?
  // `implement = "<virtual pkg path>"` — this package provides the concrete
  // implementation of the named virtual package's interface. `None` = not an impl.
  implement : String?
  // `overrides = ["<impl pkg path>", …]` — for a consumer (usually the `main`):
  // pick which implementation package satisfies each imported virtual package.
  overrides : Array[String]
  // `sub-package = { files = [...], import = [...] }` — declares a SUB-PACKAGE: a
  // subset of this directory's files compiled as a separate unit with its own
  // (smaller) import list, used to break dependency cycles. `None` = no sub-package.
  sub_package : SubPackageDecl?
  // `"link": { ... }` — per-backend link settings (exports, wasm memory layout,
  // js format, native cc overrides), applied when this package is the link root.
  // A link object on a NON-main package also marks it linkable (a library
  // artifact is produced by `moon build`) — see [`LinkConfig::need_link`].
  link : LinkConfig?
  // `"link": true` — no settings, just "link this package even though it is not
  // main". Mirrors moon's `force_link` (named `is_linked` here). (`"link": false` is
  // a no-op, like moon.)
  is_linked : Bool
  // `warnings` / `alert-list` — diagnostic control passed to moonc as `-w <list>`
  // / `-alert <list>`. `None` = compiler defaults. (moonc reads these from a JSON
  // `moon.pkg.json` itself, but NOT from the DSL `moon.pkg`, so mymoon passes them
  // as flags to make both formats behave identically.)
  warn_list : String?
  alert_list : String?
  // `bin-name` — for a `main` package, override the output executable's filename
  // stem (else the flattened fqn is used). `bin-target` — the backend this binary
  // is built for, overriding the global `--target`. Both `None` by default.
  bin_name : String?
  bin_target : String?
  // `supported-targets` — the backends this package builds for, resolved to a
  // sorted backend-name set. `None` = omitted = every backend. A build for a
  // backend NOT in this set is gated (skipped/errored) downstream.
  supported_targets : Array[String]?
  // `rule = [{ name, command }, …]` — named pre-build command templates a
  // `pre-build` entry of this package may reference by name (package-LOCAL rules;
  // moon calls them `local_rules`). Resolved against module rules in `discover`.
  local_rules : Array[ModRule]
  // `max-concurrent-tests` — cap on concurrent `async test`s, passed to
  // `moon generate-test-driver --max-concurrent-tests <N>`. `None` = no cap.
  max_concurrent_tests : Int?
}

///|
/// The `"link"` object of a `moon.pkg` manifest: one optional sub-config per
/// backend. Mirrors moon's `moonutil::package::Link` — there is no `llvm` entry
/// (the LLVM backend reuses `native`).
pub(all) struct LinkConfig {
  wasm : WasmLinkConfig?
  wasm_gc : WasmGcLinkConfig?
  js : JsLinkConfig?
  native : NativeLinkConfig?
} derive(Debug, ToJson, FromJson)

///|
pub extend LinkConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend LinkConfig with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend LinkConfig with ToJson::{to_json}

///|
/// `link.wasm.import-memory = { "module": ..., "name": ... }` — import the
/// linear memory instead of defining it (`-import-memory-module/-name`).
pub(all) struct ImportMemory {
  module_name : String // JSON key "module"
  name : String
} derive(Debug, ToJson, FromJson)

///|
pub extend ImportMemory with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImportMemory with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend ImportMemory with ToJson::{to_json}

///|
/// `link.wasm.memory-limits = { "min": ..., "max": ... }` — wasm memory limits
/// in pages (`-memory-limits-min/-max`). Both fields required, like moon.
pub(all) struct MemoryLimits {
  min : Int
  max : Int
} derive(Debug, ToJson, FromJson)

///|
pub extend MemoryLimits with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend MemoryLimits with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend MemoryLimits with ToJson::{to_json}

///|
/// `link.wasm` — the linear-wasm backend's link settings.
pub(all) struct WasmLinkConfig {
  exports : Array[String] //          `-exported_functions=a,b:ext` ("name" or "name:exportName")
  heap_start_address : Int? //        `-heap-start-address <addr>` (linear wasm only)
  import_memory : ImportMemory?
  memory_limits : MemoryLimits?
  shared_memory : Bool //             `-shared-memory` (bare flag, only when true)
  export_memory_name : String? //     `-export-memory-name <name>`
  flags : Array[String] //            appended to `moonc link-core` verbatim
} derive(Debug, ToJson, FromJson)

///|
pub extend WasmLinkConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend WasmLinkConfig with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend WasmLinkConfig with ToJson::{to_json}

///|
/// `link.wasm-gc` — like `link.wasm` minus `heap-start-address` (no linear heap),
/// plus the js-string-builtins switches.
pub(all) struct WasmGcLinkConfig {
  exports : Array[String]
  import_memory : ImportMemory?
  memory_limits : MemoryLimits?
  shared_memory : Bool
  export_memory_name : String?
  use_js_builtin_string : Bool //         `-use-js-builtin-string`
  imported_string_constants : String? //  `-imported-string-constants <ns>`
  flags : Array[String]
} derive(Debug, ToJson, FromJson)

///|
pub extend WasmGcLinkConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend WasmGcLinkConfig with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend WasmGcLinkConfig with ToJson::{to_json}

///|
/// `link.js` — exports plus the emitted module `format`. The format defaults to
/// `"esm"` (moon's `JsFormat::default`); `-js-format` is emitted only when the
/// `link.js` object exists at all, so its presence is meaningful by itself.
pub(all) struct JsLinkConfig {
  exports : Array[String]
  format : String // "esm" | "cjs" | "iife"
} derive(Debug, ToJson, FromJson)

///|
pub extend JsLinkConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend JsLinkConfig with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend JsLinkConfig with ToJson::{to_json}

///|
/// `link.native` — C toolchain overrides. The `cc*` trio applies to the final
/// executable step (compiling the moonc-emitted `.c` and linking); the
/// `stub_cc*` trio to this package's own C-stub compiles. Flag strings are
/// whitespace-separated words (moon shlex-splits; we split on spaces).
pub(all) struct NativeLinkConfig {
  exports : Array[String]
  cc : String?
  cc_flags : String?
  cc_link_flags : String?
  stub_cc : String?
  stub_cc_flags : String?
  stub_cc_link_flags : String?
} derive(Debug, ToJson, FromJson)

///|
pub extend NativeLinkConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend NativeLinkConfig with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend NativeLinkConfig with ToJson::{to_json}

///|
/// Whether a link object marks this package linkable on `backend` ("wasm" /
/// "wasm-gc" / "js" / "native"). Mirrors moon's `Link::need_link`: any object at
/// all suffices for wasm / wasm-gc / js, but on native only a `link.native`
/// carrying `cc` / `cc-flags` / `cc-link-flags` / `exports` triggers linking
/// (a stub-only `link.native` configures stub compiles, not a link artifact).
pub fn LinkConfig::need_link(self : LinkConfig, backend : String) -> Bool {
  match backend {
    // native and llvm share `link.native`: a link artifact triggers only when the
    // block carries cc / flags / exports (a stub-only block configures stub compiles).
    "native" | "llvm" =>
      match self.native {
        Some(n) =>
          n.cc is Some(_) ||
          n.cc_flags is Some(_) ||
          n.cc_link_flags is Some(_) ||
          n.exports.length() > 0
        None => false
      }
    _ => true
  }
}

///|
/// A sub-package declaration: a subset of the package's files (`files`, paths
/// relative to the package root) compiled separately with their own `imports`.
/// The sub-package keeps the parent's `-pkg` name; only its artifact files carry
/// a `_sub` suffix.
pub(all) struct SubPackageDecl {
  files : Array[String]
  imports : Array[ImportSpec]
} derive(ToJson, FromJson)

///|
pub extend SubPackageDecl with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend SubPackageDecl with ToJson::{to_json}

///|
/// A virtual package declaration. `has_default` = the virtual package ALSO ships a
/// default implementation (its own `.mbt` source), used when a consumer gives no
/// `override` for it.
pub(all) struct VirtualConfig {
  has_default : Bool
}

///|
/// One `pre-build` codegen rule: run `command` to produce `output` from `input`.
/// Paths are verbatim from the manifest (package_name-relative); the command may use
/// `$input` / `$output` / `$pkg_dir` placeholders, expanded at lowering time.
/// Mirrors moonbuild's `MoonPkgGenerate::Direct`.
pub(all) struct PrebuildRule {
  input : Array[String]
  output : Array[String]
  // The shell command to run. For a NAMED-rule entry (`rule` is `Some`), this is
  // empty at decode time and filled by `discover` from the named rule's command.
  command : String
  // `{ "rule": "<name>", … }` — reference a named rule (defined in moon.pkg
  // `rule` / moon.mod `rule`) instead of an inline `command`. `None` = inline.
  rule : String?
} derive(ToJson, FromJson)

///|
pub extend PrebuildRule with @moonbitlang/core/json.FromJson::{from_json}

///|
pub extend PrebuildRule with ToJson::{to_json}

///|
/// A named, reusable pre-build command template (`rule = [{ name, command }]` in a
/// moon.pkg or moon.mod). A pre-build entry can reference one by name instead of
/// inlining its command. Mirrors moon's `MoonModRule`.
pub(all) struct ModRule {
  name : String
  command : String
} derive(Debug)

///|
pub extend ModRule with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A field that may be written as a single string or a list of strings.
fn as_string_or_array(
  field : String,
  v : Value,
) -> Array[String] raise DecodeError {
  match v {
    Str(s) => [s]
    Array(_) => as_string_array(field, v)
    _ => raise WrongType(field~, expected="string or array of strings")
  }
}

///|
/// Decode one `pre-build` entry object `{ input, output, command }`.
fn as_prebuild_rule(v : Value) -> PrebuildRule raise DecodeError {
  match v {
    Object(m) => {
      let input = match m.get("input") {
        Some(x) => as_string_or_array("input", x)
        None => []
      }
      let output = match m.get("output") {
        Some(x) => as_string_or_array("output", x)
        None => []
      }
      // Either an inline `command` (Direct) or a `rule` reference. The named-rule
      // command is resolved later, in `discover` (it may live in moon.mod).
      let rule = match m.get("rule") {
        Some(x) => Some(as_string("rule", x))
        None => None
      }
      let command = match m.get("command") {
        Some(x) => as_string("command", x)
        None =>
          if rule is Some(_) {
            ""
          } else {
            raise MissingField("pre-build.command or pre-build.rule")
          }
      }
      { input, output, command, rule }
    }
    _ => raise WrongType(field="pre-build", expected="object")
  }
}

///|
/// Decode a `rule` array `[{ name, command }, …]` of named pre-build rules.
fn as_mod_rules(v : Value) -> Array[ModRule] raise DecodeError {
  let out : Array[ModRule] = []
  match v {
    Array(items) =>
      for it in items {
        match it {
          Object(m) => {
            let name = match m.get("name") {
              Some(x) => as_string("rule.name", x)
              None => raise MissingField("rule.name")
            }
            let command = match m.get("command") {
              Some(x) => as_string("rule.command", x)
              None => raise MissingField("rule.command")
            }
            out.push({ name, command })
          }
          _ => raise WrongType(field="rule", expected="object")
        }
      }
    _ => raise WrongType(field="rule", expected="array")
  }
  out
}

///|
fn as_bool(field : String, v : Value) -> Bool raise DecodeError {
  match v {
    Bool(b) => b
    _ => raise WrongType(field~, expected="bool")
  }
}

///|
fn as_int(field : String, v : Value) -> Int raise DecodeError {
  match v {
    Int(n) => n
    _ => raise WrongType(field~, expected="integer")
  }
}

///|
/// Decode a `"link"` object's per-backend sub-configs.
fn as_link_config(v : Value) -> LinkConfig raise DecodeError {
  match v {
    Object(m) => {
      let wasm = match m.get("wasm") {
        Some(w) => Some(as_wasm_link(w))
        None => None
      }
      let wasm_gc = match m.get("wasm-gc") {
        Some(w) => Some(as_wasm_gc_link(w))
        None => None
      }
      let js = match m.get("js") {
        Some(j) => Some(as_js_link(j))
        None => None
      }
      let native = match m.get("native") {
        Some(n) => Some(as_native_link(n))
        None => None
      }
      { wasm, wasm_gc, js, native }
    }
    _ => raise WrongType(field="link", expected="object or bool")
  }
}

///|
fn as_import_memory(v : Value) -> ImportMemory raise DecodeError {
  match v {
    Object(m) => {
      let module_name = match m.get("module") {
        Some(s) => as_string("import-memory.module", s)
        None => raise MissingField("import-memory.module")
      }
      let name = match m.get("name") {
        Some(s) => as_string("import-memory.name", s)
        None => raise MissingField("import-memory.name")
      }
      { module_name, name }
    }
    _ => raise WrongType(field="import-memory", expected="object")
  }
}

///|
fn as_memory_limits(v : Value) -> MemoryLimits raise DecodeError {
  match v {
    Object(m) => {
      let min = match m.get("min") {
        Some(n) => as_int("memory-limits.min", n)
        None => raise MissingField("memory-limits.min")
      }
      let max = match m.get("max") {
        Some(n) => as_int("memory-limits.max", n)
        None => raise MissingField("memory-limits.max")
      }
      { min, max }
    }
    _ => raise WrongType(field="memory-limits", expected="object")
  }
}

///|
/// The fields shared by `link.wasm` / `link.wasm-gc`, pulled from object `m`.
fn wasm_common(
  m : Map[String, Value],
) -> (Array[String], ImportMemory?, MemoryLimits?, Bool, String?, Array[String]) raise DecodeError {
  let exports = match m.get("exports") {
    Some(e) => as_string_array("link.exports", e)
    None => []
  }
  let import_memory = match m.get("import-memory") {
    Some(im) => Some(as_import_memory(im))
    None => None
  }
  let memory_limits = match m.get("memory-limits") {
    Some(ml) => Some(as_memory_limits(ml))
    None => None
  }
  let shared_memory = match m.get("shared-memory") {
    Some(b) => as_bool("shared-memory", b)
    None => false
  }
  let export_memory_name = match m.get("export-memory-name") {
    Some(s) => Some(as_string("export-memory-name", s))
    None => None
  }
  let flags = match m.get("flags") {
    Some(f) => as_string_array("link.flags", f)
    None => []
  }
  (
    exports, import_memory, memory_limits, shared_memory, export_memory_name, flags,
  )
}

///|
fn as_wasm_link(v : Value) -> WasmLinkConfig raise DecodeError {
  match v {
    Object(m) => {
      let (
        exports,
        import_memory,
        memory_limits,
        shared_memory,
        export_memory_name,
        flags,
      ) = wasm_common(m)
      let heap_start_address = match m.get("heap-start-address") {
        Some(n) => Some(as_int("heap-start-address", n))
        None => None
      }
      {
        exports,
        heap_start_address,
        import_memory,
        memory_limits,
        shared_memory,
        export_memory_name,
        flags,
      }
    }
    _ => raise WrongType(field="link.wasm", expected="object")
  }
}

///|
fn as_wasm_gc_link(v : Value) -> WasmGcLinkConfig raise DecodeError {
  match v {
    Object(m) => {
      let (
        exports,
        import_memory,
        memory_limits,
        shared_memory,
        export_memory_name,
        flags,
      ) = wasm_common(m)
      let use_js_builtin_string = match m.get("use-js-builtin-string") {
        Some(b) => as_bool("use-js-builtin-string", b)
        None => false
      }
      let imported_string_constants = match m.get("imported-string-constants") {
        Some(s) => Some(as_string("imported-string-constants", s))
        None => None
      }
      {
        exports,
        import_memory,
        memory_limits,
        shared_memory,
        export_memory_name,
        use_js_builtin_string,
        imported_string_constants,
        flags,
      }
    }
    _ => raise WrongType(field="link.wasm-gc", expected="object")
  }
}

///|
fn as_js_link(v : Value) -> JsLinkConfig raise DecodeError {
  match v {
    Object(m) => {
      let exports = match m.get("exports") {
        Some(e) => as_string_array("link.js.exports", e)
        None => []
      }
      let format = match m.get("format") {
        Some(f) =>
          match as_string("link.js.format", f) {
            "esm" | "cjs" | "iife" as fmt => fmt
            _ =>
              raise WrongType(
                field="link.js.format",
                expected="\"esm\", \"cjs\" or \"iife\"",
              )
          }
        None => "esm"
      }
      { exports, format }
    }
    _ => raise WrongType(field="link.js", expected="object")
  }
}

///|
fn as_native_link(v : Value) -> NativeLinkConfig raise DecodeError {
  match v {
    Object(m) => {
      let exports = match m.get("exports") {
        Some(e) => as_string_array("link.native.exports", e)
        None => []
      }
      let opt = fn(key : String) -> String? raise DecodeError {
        match m.get(key) {
          Some(s) => Some(as_string("link.native." + key, s))
          None => None
        }
      }
      {
        exports,
        cc: opt("cc"),
        cc_flags: opt("cc-flags"),
        cc_link_flags: opt("cc-link-flags"),
        stub_cc: opt("stub-cc"),
        stub_cc_flags: opt("stub-cc-flags"),
        stub_cc_link_flags: opt("stub-cc-link-flags"),
      }
    }
    _ => raise WrongType(field="link.native", expected="object")
  }
}

///|
/// An import item is either a bare path string or `{ "path": ..., "alias": ... }`.
/// Either way we want its path.
fn import_spec(v : Value) -> ImportSpec raise DecodeError {
  match v {
    Str(s) => { path: s, import_alias: None, sub_package: false }
    Object(m) => {
      let path = match m.get("path") {
        Some(Str(s)) => s
        _ => raise WrongType(field="import", expected="import item with a path")
      }
      let import_alias = match m.get("alias") {
        Some(Str(a)) => Some(a)
        _ => None
      }
      let sub_package = match m.get("sub-package") {
        Some(b) => as_bool("sub-package", b)
        None => false
      }
      { path, import_alias, sub_package }
    }
    _ => raise WrongType(field="import", expected="string or import object")
  }
}

///|
/// Decode untyped DSL entries into a typed `MoonPkg`. Unknown keys are ignored.
pub fn decode_pkg(dsl : Array[(String, Value)]) -> MoonPkg raise DecodeError {
  let imports : Array[ImportSpec] = []
  let wbtest_imports : Array[ImportSpec] = []
  let test_imports : Array[ImportSpec] = []
  // Backend-conditional imports: `import {} for "<backend>"` → these, keyed by
  // backend name. ADDITIONAL to `imports` when building for that backend.
  let cond_imports : Map[String, Array[ImportSpec]] = Map([])
  let mut is_main = false
  let mut native_stub : Array[String] = []
  let mut needs_translate_moonbit_h = false
  let prebuild : Array[PrebuildRule] = []
  let targets : Map[String, CondExpr] = Map([])
  let mut virtual_pkg : VirtualConfig? = None
  let mut implement : String? = None
  let mut overrides : Array[String] = []
  let mut sub_package : SubPackageDecl? = None
  let mut link : LinkConfig? = None
  let mut is_linked = false
  let mut warn_list : String? = None
  let mut alert_list : String? = None
  let mut bin_name : String? = None
  let mut bin_target : String? = None
  let mut supported_targets : Array[String]? = None
  let mut local_rules : Array[ModRule] = []
  let mut max_concurrent_tests : Int? = None
  // `dev_build(...)` is the MoonPkg-DSL spelling for a `pre-build` entry: each
  // `dev_build(rule~, input~, output~)` call is one codegen rule, lowered into
  // `prebuild` below. Upstream forbids mixing it with an explicit `pre-build`
  // list in the same package, so we track which surfaces appeared and conflict
  // at the end. (cf. moonutil `convert_pkg_dsl_to_package`.)
  let mut saw_dev_build = false
  let mut saw_pre_build = false
  for entry in dsl {
    let (key, v) = entry
    match key {
      "import" =>
        match v {
          Array(items) =>
            for it in items {
              imports.push(import_spec(it))
            }
          _ => raise WrongType(field="import", expected="array")
        }
      // Test-only import lists, additional to `import`. Sourced ONLY from the DSL
      // `import {} for "wbtest"/"test"` block, which the parser lowers to these
      // internal `for-wbtest`/`for-test` keys. The legacy literal `test-import` /
      // `wbtest-import` keys are deprecated in moon (→ the `for "…"` block) and are
      // intentionally not accepted here.
      "for-wbtest" =>
        match v {
          Array(items) =>
            for it in items {
              wbtest_imports.push(import_spec(it))
            }
          _ => raise WrongType(field="for-wbtest", expected="array")
        }
      "for-test" =>
        match v {
          Array(items) =>
            for it in items {
              test_imports.push(import_spec(it))
            }
          _ => raise WrongType(field="for-test", expected="array")
        }
      // JSON manifests carry `targets` at top level; the DSL nests it inside
      // `options(...)` (handled below). Support both.
      "targets" => parse_targets_into(v, targets)
      // Virtual-package fields. Carried at the manifest top level (both DSL and
      // JSON); a virtual package's `.mbti` interface is located by `discover`.
      "virtual" => virtual_pkg = Some(as_virtual_config(v))
      "implement" => implement = Some(as_string("implement", v))
      "overrides" => overrides = as_string_array("overrides", v)
      "sub-package" => sub_package = Some(as_sub_package(v))
      // `link`: `true` forces linking with no settings (the bool itself carries
      // no config, mirroring moon's `force_link`); an object holds the
      // per-backend settings. `false` is a no-op.
      "link" =>
        match v {
          Bool(b) => is_linked = b
          _ => link = Some(as_link_config(v))
        }
      // `pkgtype(kind: …)` — the current DSL's package-kind declaration (also
      // accepted as a JSON top-level key), replacing the deprecated
      // `options("is-main": true)` / `options(link: true)` spellings:
      //   * "executable"       → a main package (is_main)
      //   * "foreign_library"  → a linked, exportable library (is_linked)
      //   * "library"          → the default (no-op)
      "pkgtype" =>
        match v {
          Object(m) =>
            match m.get("kind") {
              Some(Str("executable")) => is_main = true
              Some(Str("foreign_library")) => is_linked = true
              Some(Str("library")) => ()
              _ =>
                raise WrongType(
                  field="pkgtype",
                  expected="kind: \"library\" | \"executable\" | \"foreign_library\"",
                )
            }
          _ => raise WrongType(field="pkgtype", expected="object")
        }
      // Diagnostic + binary-output knobs. `warnings` is the current top-level key
      // (the old `"warn-list"` syntax is deprecated in moon — dropped here). The
      // remaining hyphen keys stay top-level in JSON / nested in `options(...)`.
      "warnings" => warn_list = Some(as_string("warnings", v))
      "alert-list" => alert_list = Some(as_string("alert-list", v))
      "bin-name" => bin_name = Some(as_string("bin-name", v))
      "bin-target" => bin_target = Some(as_string("bin-target", v))
      // JSON manifests (real moon) carry `is-main` / `native-stub` at the top
      // level; the DSL nests them inside `options(...)` (handled below). Support
      // both, else `moon build` on a JSON-manifest project finds no `main`. Accept
      // the underscore form too (mymoon's own `.pkg` convention).
      "is-main" | "is_main" => is_main = as_bool("is-main", v)
      "native-stub" | "native_stub" =>
        native_stub = as_string_array("native-stub", v)
      "import-moonbit-h" | "import_moonbit_h" =>
        needs_translate_moonbit_h = as_bool("import-moonbit-h", v)
      // Accept both the JSON-canonical hyphen and the underscore form mymoon's own
      // `.pkg` files use (`supported_targets = "native"`).
      "supported-targets" | "supported_targets" =>
        supported_targets = Some(as_supported_targets(v))
      "rule" => local_rules = as_mod_rules(v)
      "max-concurrent-tests" =>
        max_concurrent_tests = Some(as_int("max-concurrent-tests", v))
      // Upstream MoonPkg has two surface syntaxes for the SAME field, both
      // supported here: the JSON manifest carries `pre-build` at top level
      // (moonutil `MoonPkgJSON.pre_build`), while the MoonPkg DSL nests it inside
      // `options(...)` (handled below; cf. moonutil `moon_pkg::parser`). Both are
      // real moon — the DSL is upstream's, not a mymoon invention.
      "pre-build" => {
        saw_pre_build = true
        match v {
          Array(rules) =>
            for r in rules {
              prebuild.push(as_prebuild_rule(r))
            }
          _ => raise WrongType(field="pre-build", expected="array")
        }
      }
      // `dev_build(rule~, input~, output~)` — the DSL alias for one `pre-build`
      // entry. Each occurrence is a single rule object; the parser emits one
      // `("dev_build", Object{…})` entry per call.
      "dev_build" => {
        saw_dev_build = true
        prebuild.push(as_prebuild_rule(v))
      }
      "options" =>
        match v {
          Object(m) => {
            match m.get("is-main") {
              Some(b) => is_main = as_bool("is-main", b)
              None =>
                match m.get("is_main") {
                  Some(b) => is_main = as_bool("is-main", b)
                  None => ()
                }
            }
            match m.get("native-stub") {
              Some(a) => native_stub = as_string_array("native-stub", a)
              None =>
                match m.get("native_stub") {
                  Some(a) => native_stub = as_string_array("native-stub", a)
                  None => ()
                }
            }
            match m.get("import-moonbit-h") {
              Some(b) =>
                needs_translate_moonbit_h = as_bool("import-moonbit-h", b)
              None =>
                match m.get("import_moonbit_h") {
                  Some(b) =>
                    needs_translate_moonbit_h = as_bool("import-moonbit-h", b)
                  None => ()
                }
            }
            match m.get("pre-build") {
              Some(Array(rules)) => {
                saw_pre_build = true
                for r in rules {
                  prebuild.push(as_prebuild_rule(r))
                }
              }
              Some(_) => raise WrongType(field="pre-build", expected="array")
              None => ()
            }
            match m.get("targets") {
              Some(tv) => parse_targets_into(tv, targets)
              None => ()
            }
            match m.get("virtual") {
              Some(vv) => virtual_pkg = Some(as_virtual_config(vv))
              None => ()
            }
            match m.get("implement") {
              Some(iv) => implement = Some(as_string("implement", iv))
              None => ()
            }
            match m.get("overrides") {
              Some(ov) => overrides = as_string_array("overrides", ov)
              None => ()
            }
            match m.get("sub-package") {
              Some(sv) => sub_package = Some(as_sub_package(sv))
              None => ()
            }
            match m.get("link") {
              Some(Bool(b)) => is_linked = b
              Some(lv) => link = Some(as_link_config(lv))
              None => ()
            }
            match m.get("alert-list") {
              Some(av) => alert_list = Some(as_string("alert-list", av))
              None => ()
            }
            match m.get("bin-name") {
              Some(bv) => bin_name = Some(as_string("bin-name", bv))
              None =>
                match m.get("bin_name") {
                  Some(bv) => bin_name = Some(as_string("bin-name", bv))
                  None => ()
                }
            }
            match m.get("bin-target") {
              Some(bv) => bin_target = Some(as_string("bin-target", bv))
              None =>
                match m.get("bin_target") {
                  Some(bv) => bin_target = Some(as_string("bin-target", bv))
                  None => ()
                }
            }
            match m.get("supported-targets") {
              Some(sv) => supported_targets = Some(as_supported_targets(sv))
              None =>
                match m.get("supported_targets") {
                  Some(sv) => supported_targets = Some(as_supported_targets(sv))
                  None => ()
                }
            }
            match m.get("rule") {
              Some(rv) => local_rules = as_mod_rules(rv)
              None => ()
            }
            match m.get("max-concurrent-tests") {
              Some(mv) =>
                max_concurrent_tests = Some(as_int("max-concurrent-tests", mv))
              None =>
                match m.get("max_concurrent_tests") {
                  Some(mv) =>
                    max_concurrent_tests = Some(
                      as_int("max-concurrent-tests", mv),
                    )
                  None => ()
                }
            }
          }
          _ => raise WrongType(field="options", expected="object")
        }
      _ =>
        // Conditional imports: the parser lowers `import {} for "<cond>"` to a
        // `for-<cond>` key (test/wbtest handled above). The condition is either a
        // known backend (`native`/…) or a platform spec (`linux`/`windows-gnu`/…);
        // both name-spaces are disjoint. Anything else is an ignored unknown
        // statement. The backend-vs-platform classification happens later, in
        // pkg_solve; here we only validate + collect.
        match key.strip_prefix("for-") {
          Some(section_view) => {
            let section = section_view.to_owned()
            // A backend, or a platform spec `<os>[-<toolchain>]`. We validate only
            // the `<os>` head here (the toolchain part + the precise parse live in
            // `@os.Platform`, a native-only package `config` must not depend on —
            // it stays backend-agnostic). pkg_solve does the full classification.
            let os_head = match section.split_once("-") {
              Some((head, _)) => head
              None => section
            }
            if section is ("native" | "wasm-gc" | "wasm" | "js" | "llvm") ||
              os_head is ("linux" | "macos" | "windows") {
              match v {
                Array(items) => {
                  let arr = cond_imports.get_or_init(section, () => [])
                  for it in items {
                    arr.push(import_spec(it))
                  }
                }
                _ => raise WrongType(field=key, expected="array")
              }
            }
          }
          None => ()
        }
    }
  }
  if saw_dev_build && saw_pre_build {
    raise Conflict("`dev_build` cannot be used together with `pre-build`")
  }
  {
    imports,
    wbtest_imports,
    test_imports,
    cond_imports,
    is_main,
    native_stub,
    needs_translate_moonbit_h,
    prebuild,
    targets,
    virtual_pkg,
    implement,
    overrides,
    sub_package,
    link,
    is_linked,
    warn_list,
    alert_list,
    bin_name,
    bin_target,
    supported_targets,
    local_rules,
    max_concurrent_tests,
  }
}

///|
/// All backends mymoon can target. `all` in a `supported-targets` expression
/// expands to these (plus the inert `llvm`, accepted as a token but never built).
let all_backends : Array[String] = ["js", "native", "wasm", "wasm-gc"]

///|
/// Decode a `supported-targets` value into a sorted backend-name set: the
/// EXPRESSION string form (a `+`/`-` term DSL over `wasm-gc`/`native`/`wasm`/
/// `llvm`/`all`/`js`). The legacy ARRAY form `["js", "native"]` is intentionally
/// NOT accepted — current moon deprecation-warns it in favor of the top-level
/// `supported_targets = "<expr>"` string.
fn as_supported_targets(v : Value) -> Array[String] raise DecodeError {
  match v {
    Str(s) => parse_supported_expr(s)
    Array(items) => {
      let sel : Set[String] = Set([])
      for item in items {
        for target in parse_supported_expr(as_string("supported-targets", item)) {
          sel.add(target)
        }
      }
      let out = sel.to_array()
      out.sort()
      out
    }
    _ =>
      raise WrongType(
        field="supported-targets",
        expected="string expression or array of strings",
      )
  }
}

///|
/// Parse a `supported-targets` EXPRESSION string: a sequence of `+token`/`-token`
/// terms (the first term's `+` is implicit) that add/remove backends from a set.
/// `all` adds every backend (`+all`) or clears (`-all`). Tokens are matched
/// longest-first so `wasm-gc` is not read as `wasm` then `-gc`. Mirrors moon's
/// `parse_supported_targets_expr`.
fn parse_supported_expr(expr : String) -> Array[String] raise DecodeError {
  // Order matters: `wasm-gc` must be tried before `wasm`.
  let toks = ["wasm-gc", "native", "wasm", "llvm", "all", "js"]
  let cs = expr.to_array()
  let n = cs.length()
  let sel : Set[String] = Set([])
  let mut i = 0
  let mut first = true
  fn skip_ws() -> Unit {
    while i < n && cs[i] == ' ' {
      i = i + 1
    }
  }

  skip_ws()
  guard i < n else {
    raise WrongType(field="supported-targets", expected="non-empty expression")
  }
  while i < n {
    skip_ws()
    if i >= n {
      break
    }
    let op = if cs[i] == '+' {
      i = i + 1
      '+'
    } else if cs[i] == '-' {
      i = i + 1
      '-'
    } else if first {
      '+'
    } else {
      raise WrongType(field="supported-targets", expected="`+` or `-` operator")
    }
    skip_ws()
    guard i < n else {
      raise WrongType(
        field="supported-targets",
        expected="token after operator",
      )
    }
    // Longest-first token match with a boundary check.
    let mut matched : String? = None
    for cand in toks {
      if cs_starts_with(cs, i, cand) {
        let end = i + cand.length()
        if end >= n || cs[end] == '+' || cs[end] == '-' || cs[end] == ' ' {
          matched = Some(cand)
          i = end
          break
        }
      }
    }
    let token = match matched {
      Some(t) => t
      None =>
        raise WrongType(
          field="supported-targets",
          expected="known backend token (js/native/wasm/wasm-gc/llvm/all)",
        )
    }
    first = false
    if token == "all" {
      if op == '+' {
        for b in all_backends {
          sel.add(b)
        }
      } else {
        sel.clear()
      }
    } else if op == '+' {
      sel.add(token)
    } else {
      sel.remove(token)
    }
  }
  let out = sel.to_array()
  out.sort()
  out
}

///|
/// Whether the chars `cs[pos..]` begin with the string `s`.
fn cs_starts_with(cs : Array[Char], pos : Int, s : String) -> Bool {
  let sc = s.to_array()
  if pos + sc.length() > cs.length() {
    return false
  }
  for k in 0..<sc.length() {
    if cs[pos + k] != sc[k] {
      return false
    }
  }
  true
}

///|
/// Decode a `sub-package` object `{ files = [...], import = [...] }`.
fn as_sub_package(v : Value) -> SubPackageDecl raise DecodeError {
  match v {
    Object(m) => {
      let files = match m.get("files") {
        Some(f) => as_string_array("sub-package.files", f)
        None => raise MissingField("sub-package.files")
      }
      let imports : Array[ImportSpec] = []
      match m.get("import") {
        Some(Array(items)) =>
          for it in items {
            imports.push(import_spec(it))
          }
        Some(_) => raise WrongType(field="sub-package.import", expected="array")
        None => ()
      }
      { files, imports }
    }
    _ => raise WrongType(field="sub-package", expected="object")
  }
}

///|
/// Decode a `virtual` value into a [`VirtualConfig`]. Accepts an object
/// `{ "has-default": <bool> }` (missing key → `false`), or a bare bool / empty
/// value (→ `has_default = false`) for the shorthand `virtual = {}`.
fn as_virtual_config(v : Value) -> VirtualConfig raise DecodeError {
  match v {
    Object(m) => {
      let has_default = match m.get("has-default") {
        Some(b) => as_bool("has-default", b)
        None => false
      }
      { has_default, }
    }
    Bool(b) => { has_default: b }
    _ => raise WrongType(field="virtual", expected="object or bool")
  }
}

///|
/// Decode a `targets` object `{ "<file>": <cond-expr> }` into the map.
fn parse_targets_into(
  v : Value,
  into : Map[String, CondExpr],
) -> Unit raise DecodeError {
  match v {
    Object(m) =>
      for fname, cond in m {
        into[fname] = parse_cond_expr(cond)
      }
    _ => raise WrongType(field="targets", expected="object")
  }
}

///|
/// Decode untyped DSL entries into a typed `MoonMod`. Unknown keys are ignored;
/// a missing required field or a wrong-typed value raises `DecodeError`.
pub fn decode_mod(dsl : Array[(String, Value)]) -> MoonMod raise DecodeError {
  let mut name : String? = None
  let mut version : String? = None
  let mut keywords : Array[String] = []
  let mut deps : Array[Dependency] = []
  let mut source = ""
  let mut compile_flags : Array[String] = []
  let mut link_flags : Array[String] = []
  let mut supported_targets : Array[String]? = None
  let mut rules : Array[ModRule] = []
  let mut warn_list : String? = None
  let mut alert_list : String? = None
  let mut preferred_target : String? = None
  let mut includes : Array[String] = []
  let mut excludes : Array[String] = []
  let mut unstable_prebuild : String? = None
  let mut bin_deps : Array[BinDep] = []
  for entry in dsl {
    let (key, v) = entry
    match key {
      "name" => name = Some(as_string("name", v))
      "bin-deps" | "bin_deps" => bin_deps = as_bin_deps(v)
      "--moonbit-unstable-prebuild" | "moonbit-unstable-prebuild" =>
        unstable_prebuild = Some(as_string("--moonbit-unstable-prebuild", v))
      "supported-targets" | "supported_targets" =>
        supported_targets = Some(as_supported_targets(v))
      "rule" => rules = as_mod_rules(v)
      "warnings" => warn_list = Some(as_string("warnings", v))
      "alert-list" => alert_list = Some(as_string("alert-list", v))
      // Hyphen (JSON `moon.mod.json`) AND underscore (DSL `moon.mod`) spellings.
      "preferred-target" | "preferred_target" =>
        preferred_target = Some(as_backend("preferred-target", v))
      "version" => version = Some(as_version("version", v))
      "keywords" => keywords = as_string_array("keywords", v)
      "include" => includes = as_string_array("include", v)
      "exclude" => excludes = as_string_array("exclude", v)
      "deps" => deps = as_deps(v)
      // JSON manifests carry `source` at the top level; the DSL lowers it from
      // `options(source: "src")` (handled below). Support both.
      "source" => source = as_string("source", v)
      "compile-flags" => compile_flags = as_string_array("compile-flags", v)
      "link-flags" => link_flags = as_string_array("link-flags", v)
      "options" =>
        match v {
          Object(m) => {
            match m.get("source") {
              Some(s) => source = as_string("source", s)
              None => ()
            }
            match m.get("compile-flags") {
              Some(c) => compile_flags = as_string_array("compile-flags", c)
              None => ()
            }
            match m.get("link-flags") {
              Some(l) => link_flags = as_string_array("link-flags", l)
              None => ()
            }
            match m.get("rule") {
              Some(rv) => rules = as_mod_rules(rv)
              None => ()
            }
            match m.get("alert-list") {
              Some(av) => alert_list = Some(as_string("alert-list", av))
              None => ()
            }
            match m.get("preferred-target") {
              Some(pv) =>
                preferred_target = Some(as_backend("preferred-target", pv))
              None => ()
            }
            // `bin-deps` lives inside `options(...)` in both the JSON manifest and
            // the rust-moon DSL (its top-level whitelist rejects a bare key), so the
            // official `moon` only reads it here. Mirror that placement.
            match m.get("bin-deps") {
              Some(bv) => bin_deps = as_bin_deps(bv)
              None => ()
            }
          }
          _ => ()
        }
      _ => () // ignore unknown fields
    }
  }
  let name = match name {
    Some("") =>
      raise WrongType(field="name", expected="a non-empty module name")
    Some(n) => n
    None => raise MissingField("name")
  }
  {
    name,
    version,
    keywords,
    deps,
    source,
    compile_flags,
    link_flags,
    supported_targets,
    rules,
    warn_list,
    alert_list,
    preferred_target,
    includes,
    excludes,
    unstable_prebuild,
    bin_deps,
  }
}

///|
/// Decode a backend-name value (`wasm-gc`/`native`/`js`/`wasm`), validating it.
/// `llvm` is rejected (mymoon does not build it); other strings error.
fn as_backend(field : String, v : Value) -> String raise DecodeError {
  let s = as_string(field, v)
  match s {
    "wasm-gc" | "native" | "js" | "wasm" => s
    _ => raise WrongType(field~, expected="backend (wasm-gc/native/js/wasm)")
  }
}

///|
/// Decode the `deps = { "name": <spec> }` object. Each spec is either a bare
/// version string (registry) or an object carrying `git`+`ref` / `path` /
/// `version`.
/// Decode the `bin-deps = { "name": <spec> }` object. Each spec is either a bare
/// version string (registry) or an object carrying `path` (local) / `version`
/// (registry) plus an optional `bin-pkg` list. Mirrors rust moon's
/// `BinaryDependencyInfoJson` (untagged Simple | Detailed).
fn as_bin_deps(v : Value) -> Array[BinDep] raise DecodeError {
  let out : Array[BinDep] = []
  match v {
    Object(m) =>
      for name, spec in m {
        out.push(as_bin_dep(name, spec))
      }
    _ => raise WrongType(field="bin-deps", expected="object")
  }
  out
}

///|
/// Decode one `bin-deps` entry. `"name@?": "1.2.3"` → registry; an object with
/// `path` → local, with `version` → registry; `bin-pkg`/`bin_pkg` (string or
/// array) selects which packages to build (empty = all main/linkable).
fn as_bin_dep(name : String, spec : Value) -> BinDep raise DecodeError {
  match spec {
    Str(version) =>
      {
        name,
        source: BinDepSource::Registry(
          version=validate_version("bin-deps.\{name}", version),
        ),
        bin_pkg: [],
      }
    Object(m) => {
      let source = match m.get("path") {
        Some(p) =>
          BinDepSource::Local(path=as_string("bin-deps.\{name}.path", p))
        None =>
          match m.get("version") {
            Some(ver) =>
              BinDepSource::Registry(
                version=as_version("bin-deps.\{name}.version", ver),
              )
            None =>
              raise WrongType(
                field="bin-deps.\{name}",
                expected="object with `path` or `version`",
              )
          }
      }
      let bin_pkg = match m.get("bin-pkg") {
        Some(b) => as_string_or_array("bin-deps.\{name}.bin-pkg", b)
        None =>
          match m.get("bin_pkg") {
            Some(b) => as_string_or_array("bin-deps.\{name}.bin-pkg", b)
            None => []
          }
      }
      { name, source, bin_pkg }
    }
    _ => raise WrongType(field="bin-deps.\{name}", expected="string or object")
  }
}

///|
fn as_deps(v : Value) -> Array[Dependency] raise DecodeError {
  let out : Array[Dependency] = []
  match v {
    Object(m) =>
      for name, spec in m {
        out.push(as_dependency(name, spec))
      }
    _ => raise WrongType(field="deps", expected="object")
  }
  out
}

///|
/// Decode one resolved dep spec. A `moon.mod` dependency is ALWAYS a registry
/// dependency — `Str(version)` or `Object{ version }`. Anything else (a `path` local,
/// or any other object) has no `version` and is rejected. Local modules are developed
/// together via `moon.work` members, not a manifest path dep; the `path` case gets a
/// pointed message since it is the likely mistake.
fn as_dependency(name : String, spec : Value) -> Dependency raise DecodeError {
  match spec {
    Str(version) =>
      Registry(name~, version=validate_version("deps.\{name}", version))
    Object(m) =>
      if m.contains("path") {
        // Local-path deps in a manifest are not supported — use `moon.work`.
        raise WrongType(
          field="deps.\{name}",
          expected="version string (local-path dependencies are not supported in a manifest — list the module in `moon.work` instead)",
        )
      } else {
        match m.get("version") {
          Some(ver) =>
            Registry(name~, version=as_version("deps.\{name}.version", ver))
          None =>
            raise WrongType(
              field="deps.\{name}",
              expected="version string, or object with version",
            )
        }
      }
    _ => raise WrongType(field="deps.\{name}", expected="string or object")
  }
}
