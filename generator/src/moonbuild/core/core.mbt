// The build-action model. An `Action` is a node in the build graph: a structured
// description of one build step.

///|
/// The MoonBit runtime header, the sole header `import-moonbit-h` translate-c's (it
/// is the only useful header in the toolchain `include_dir`). Its stem `moonbit`
/// becomes the Zig module name a stub `@import`s.
pub const MOONBIT_H : String = "moonbit.h"

///|
/// One imported `.mi` interface, wired as `-i <mi>:<import_alias>`.
pub(all) struct MiDep {
  mi : String //    path to the dependency's `.mi`
  import_alias : String // the short import import_alias
}

///|
/// A standard-library sub-package_name import, provided by the bundle. Kept structured
/// (sub/last/import_alias) rather than as a baked path so it survives into the digest
/// identity and lets each renderer build the path its own way.
pub(all) struct StdImport {
  sub : String //   path under `moonbitlang/core/` (e.g. `immut/sorted_map`)
  last : String //  last segment (the `.mi` filename stem)
  import_alias : String
}

///|
/// Virtual-package wiring for a `Compile`. Set when a `build-package` must be
/// checked against a virtual package's interface `.mi`:
///   - own interface : `is_impl = false` → `-check-mi`.
///   - foreign interface :
///     `is_impl = true` → `-check-mi` + `-impl-virtual`.
/// `pkg_name`/`pkg_root` are the VIRTUAL package's (for the extra `-pkg-sources`).
/// The `mi` path is excluded from the cache identity;
/// `pkg_name` + `is_impl` are the path-free semantic legs.
pub(all) struct VirtualImpl {
  mi : String //        the virtual interface `.mi` to check against
  pkg_name : String //  the virtual package's fqn (`-pkg-sources`)
  pkg_root : String //  the virtual package's source root (`-pkg-sources`)
  is_impl : Bool //     true → implementing a foreign virtual (`-impl-virtual`)
}

///|
/// The wasm/wasm-gc link settings of a `LinkCore`, lowered from the package's
/// `link.wasm` / `link.wasm-gc` manifest block. Path-free and backend-filtered
/// at plan time (only the ACTIVE backend's block is carried; `heap_start_address`
/// is only ever set for linear wasm, the js-string fields only for wasm-gc).
/// Every field feeds the cache identity — same inputs with different memory
/// layout produce different artifacts.
pub(all) struct WasmLinkOpts {
  export_memory_name : String? //         `-export-memory-name <name>`
  import_memory : (String, String)? //    `-import-memory-module <m> -import-memory-name <n>`
  memory_limits : (Int, Int)? //          `-memory-limits-min <min> -memory-limits-max <max>`
  shared_memory : Bool //                 `-shared-memory` (only when true)
  heap_start_address : Int? //            `-heap-start-address <addr>` (wasm only)
  use_js_builtin_string : Bool //         `-use-js-builtin-string` (wasm-gc only)
  imported_string_constants : String? //  `-imported-string-constants <ns>` (wasm-gc only)
  flags : Array[String] //                manifest `flags`, appended verbatim
}

///|
pub(all) enum TestDriverKind {
  Internal
  Whitebox
  Blackbox
}

///|
/// The `--driver-kind` token.
pub fn TestDriverKind::name(self : TestDriverKind) -> String {
  match self {
    Internal => "internal"
    Whitebox => "whitebox"
    Blackbox => "blackbox"
  }
}

///|
/// The structured description of a build step. Paths inside are resolved at plan time; what is
/// path-free (fqn, aliases, is_main…) feeds the cache identity via [`identity`].
pub(all) enum ActionSpec {
  /// `moonc build-package` (→ `.core`) or `moonc check` (→ `.mi`).
  Compile(
    check~ : Bool,
    sources~ : Array[String],
    fqn~ : String,
    is_main~ : Bool,
    std_bundle~ : String?, //         Some(bundle) → `-std-path` + prelude `-i`
    deps~ : Array[MiDep], //          project dependency `.mi`s
    std_imports~ : Array[StdImport], // stdlib `.mi`s from the bundle
    pkg_root~ : String, //            `-pkg-sources <fqn>:<root>`
    test_kind~ : TestDriverKind?, //  Some(kind) → a test build: `-test-mode`,
    //                                `-no-mi`, and the kind's `-<kind>-test` flag
    doctest_only~ : Array[String], // blackbox: `-doctest-only <files>` (else empty)
    workspace~ : String?, //          `-workspace-path <root>`; required for test
    //                                builds so moonc names doctest functions to
    //                                match the generated driver (else they no-op)
    all_pkgs~ : String?, //           `-all-pkgs <all_pkgs.json>`: workspace mode —
    //                                moonc lazily loads OTHER packages' `.mi` from
    //                                the listing to resolve traits referenced via
    //                                dep signatures but not imported (needed when
    //                                bundling core, whose inline tests do this)
    coverage~ : Bool, //              `-enable-coverage` + the `coverage` `.mi` import
    value_tracing~ : Bool, //         `-enable-value-tracing`: trace variable values
    virtual_impl~ : VirtualImpl?, //  Some → `-check-mi` (+ `-impl-virtual`) against
    //                                a virtual package's interface
    no_mi~ : Bool, //                 `-no-mi`: don't emit the `.mi` byproduct (test
    //                                builds, and a virtual default-impl whose `.mi`
    //                                is owned by its `build-interface`)
    warn_list~ : String?, //          `-w <list>` (diagnostic-only: NOT in identity —
    //                                it doesn't change the emitted `.core`/`.mi`)
    alert_list~ : String?, //         `-alert <list>` (likewise diagnostic-only)
    compile_flags~ : Array[String] // module `compile-flags`, appended raw. IN the
    //                                identity — `-O2`/`-D` change the output bytes.
  )
  /// `moonc build-interface`: generate a virtual package's interface `.mi` from its
  /// hand-written `.mbti` contract. The package's `.mi` is produced HERE, not by
  /// `build-package`. Consumers import this `.mi` exactly like any dependency's.
  BuildInterface(
    mbti~ : String, //           the hand-written `.mbti` (positional input)
    fqn~ : String, //            `-pkg` + `-pkg-sources`
    pkg_root~ : String, //       `-pkg-sources <fqn>:<root>`
    std_bundle~ : String?, //    Some(bundle) → `-std-path`
    deps~ : Array[MiDep] //      interface dependencies (`-i <mi>:<alias>`)
  )
  /// `moonc link-core`: link a `.core` closure into the final artifact.
  LinkCore(
    std_bundle~ : String?, //              fronts with abort.core / core.core
    cores~ : Array[String], //             ordered `.core` inputs (deps first)
    main~ : String,
    pkg_config~ : String?, //              `-pkg-config-path <main pkg moon.pkg.json>`:
    //                                     lets moonc read the link root's manifest
    //                                     link config directly (matches moon 0.9.3,
    //                                     which passes it on every link-core). A
    //                                     PATH, so it stays out of the cache identity
    //                                     — the link-relevant fields are already
    //                                     rendered as explicit `-exported_functions`
    //                                     / `-js-format` / wasm-opts switches.
    pkg_sources~ : Array[(String, String)], // (fqn, root) for `-pkg-sources`
    std_core_root~ : String?, //           `-pkg-sources moonbitlang/core:<root>`
    test_mode~ : Bool, //                  `-test-mode` (linking a test driver)
    exported_functions~ : Array[String], // test mode: `-exported_functions a,b`
    //                                     (the driver entry points); otherwise the
    //                                     manifest `link.<backend>.exports`,
    //                                     rendered `-exported_functions=a,b`
    js_format~ : String?, //               `-js-format esm|cjs|iife` (js backend,
    //                                     set iff the manifest has a `link.js`)
    wasm_opts~ : WasmLinkOpts?, //         wasm/wasm-gc memory layout + verbatim
    //                                     `flags` from `link.wasm`/`link.wasm-gc`
    link_flags~ : Array[String], //        module `link-flags`, appended raw (matters
    //                                     for the wasm/js final link)
    native_target~ : String?, //            "new native" backend: the moonc `-target`
    //                                     triple (`aarch64-apple-darwin` / …) that
    //                                     makes link-core emit a `.o` instead of `.c`.
    //                                     `None` = the normal `-target <backend>`. In
    //                                     the identity (it changes the artifact).
    output_wat~ : Bool //                  `--output-wat`: emit `.wat` text, not `.wasm`.
    //                                     Changes only the output extension, but the
    //                                     identity excludes paths — so the format bit
    //                                     must live here, else a `.wasm` and a `.wat`
    //                                     link of identical inputs share a digest and
    //                                     one restores the other's bytes from cache.
  )
  /// `moonc bundle-core`: merge a module's `.core` files (topological order, deps
  /// first) into one combined `.core` — how `moonbitlang/core` ships its
  /// `bundle/core.core`. No semantic switches beyond the input list.
  BundleCore(cores~ : Array[String])
  /// A pre-build codegen step: a free-form, already-expanded shell command.
  /// `pkg_root` (the owning package's directory), `module_root` (the cwd for
  /// execution), and `fqn` let the executor run/relativize/name the
  /// codegen step. The command itself is part of the cache identity: declared
  /// pre-build inputs plus this command define whether the generated output can
  /// be reused.
  Prebuild(
    command~ : String,
    pkg_root~ : String,
    module_root~ : String,
    fqn~ : String
  )
  /// `moon generate-test-driver`: emit a test driver `.mbt` (the action output)
  /// plus a metadata JSON. `test_sources` are the positional inputs (the test
  /// files, plus the package source for whitebox/internal); `doctest_only` is the
  /// blackbox package source scanned for doctests (empty otherwise). Unlike
  /// `Prebuild` this IS cacheable — its inputs (the scanned sources) are fully
  /// declared, so the driver is a pure function of them.
  GenerateTestDriver(
    kind~ : TestDriverKind,
    test_sources~ : Array[String],
    doctest_only~ : Array[String],
    metadata~ : String,
    pkg_name~ : String,
    coverage~ : Bool, //              `--enable-coverage`
    bench~ : Bool, //                 `--bench` (bench-mode driver) vs test mode
    max_concurrent_tests~ : Int? //   `--max-concurrent-tests <N>` (async test cap)
  )
  /// `cc` ONE toolchain runtime source into a `.o`. A pre-2026-08 toolchain ships a
  /// single `lib/runtime.c`; newer ones split it into `lib/runtime/*.c`, one action
  /// each. `cc_kind` (gcc/clang/msvc) is carried ONLY for the cache identity — gcc
  /// and clang produce incompatible `.o`s from the same source, so without it their
  /// outputs would alias in the CAS. (Version-agnostic on purpose: C is ABI-stable
  /// across compiler versions.) `simdutf` adds `-DMOONBIT_USE_SIMDUTF`; the plan
  /// decides it so the define and the linked simdutf objects agree.
  BuildRuntime(
    cc~ : String,
    include_dir~ : String,
    runtime_c~ : String,
    cc_kind~ : String,
    simdutf~ : Bool,
    debug_info~ : Bool
  )
  /// `cc` one C stub into a `.o`. `cc`/`cc_flags` honor the owning package's
  /// `link.native.stub-cc` / `stub-cc-flags` overrides (flags pre-split).
  /// `cc_kind` keys the cache identity (see `BuildRuntime`).
  /// `debug_info` follows `--strip` / `--no-strip`; `debug_mode` follows the
  /// build profile and selects fast debug optimization (`/Od` / `-Og`) instead of
  /// release optimization.
  BuildCStub(
    cc~ : String,
    include_dir~ : String,
    stub~ : String,
    cc_flags~ : Array[String],
    cc_kind~ : String,
    debug_info~ : Bool,
    debug_mode~ : Bool
  )
  /// `zig build-obj` one `.zig` stub into a `.o`. Produces a relocatable object
  /// that is archived + linked exactly like a `BuildCStub` output (the C/Zig
  /// distinction is invisible downstream). `zig` is the (possibly multi-word, e.g.
  /// `zig`) driver; `include_dir` exposes `moonbit.h` for `@cImport`/extern decls.
  /// No `cc_kind` leg: there is a single zig "kind", and the stub source is already
  /// content-hashed via the action's inputs.
  ///
  /// `modules` are translate-c-generated Zig modules (`(name, path)`) this stub may
  /// `@import("<name>")` — empty for the common stub. When non-empty the renderer
  /// switches to the explicit `--dep <name> -M<name>=<path>` module form (the bare
  /// positional `stub` form can't carry import deps). Each module's `.zig` path is
  /// also among the action `inputs` (set by `zigstub_action`), so a re-translation
  /// re-builds the stub.
  BuildZigStub(
    zig~ : String,
    include_dir~ : String,
    stub~ : String,
    modules~ : Array[(String, String)],
    // The zig/clang target triple for a cross build (`zig build-obj -target …`),
    // e.g. `x86_64-windows-msvc`. `None` for a native (host) build — the stub then
    // builds for the host default, exactly as before. Carried so the cross stub
    // object matches the cross C objects it links with.
    target~ : String?
  )
  /// `zig translate-c` one C header (in `include_dir`, e.g. `moonbit.h`) into a Zig
  /// module (`.zig`, the action output) that a `.zig` stub `@import`s. Lets a stub
  /// use the header's MACROS (which `extern` decls can't reach). The header comes
  /// from the toolchain `include_dir`, so it is NOT a tracked input (`inputs=[]`);
  /// `header` joins the cache identity so distinct headers don't alias. stdout is
  /// captured to the output (translate-c has no output-file flag) — see the executor
  /// arm. Needs `-lc` so the header's own `#include <math.h>` etc. resolve.
  TranslateC(zig~ : String, include_dir~ : String, header~ : String)
  /// `clang` one Objective-C (`.m`) / Objective-C++ (`.mm`) stub into a `.o`,
  /// archived + linked exactly like a `BuildCStub` output. ObjC is compiled by the
  /// same `clang` driver as C (the caller gates on `cc_kind == Clang` and raises
  /// `ObjcRequiresClang` otherwise), but the language is pinned with `-x
  /// objective-c[++]` so it never depends on extension sniffing. `cpp` selects
  /// ObjC++ (`.mm`). Frameworks/libs ride the owning package's `stub-cc-link-flags`
  /// (e.g. `-framework Foundation`) like any other native link need.
  BuildObjcStub(
    cc~ : String,
    include_dir~ : String,
    stub~ : String,
    cc_flags~ : Array[String],
    cc_kind~ : String,
    cpp~ : Bool,
    debug_info~ : Bool,
    debug_mode~ : Bool
  )
  /// `ar` a package_name's stub `.o`s into a `.a`.
  ArchiveCStubs(ar~ : String, objs~ : Array[String])
  /// `cc`-link the emitted `.c` + runtime + stubs + toolchain libs into an exe.
  /// `cc`/`cc_flags`/`cc_link_flags` honor the link root's `link.native.cc` /
  /// `cc-flags` / `cc-link-flags` (flags pre-split; link flags go last).
  MakeExecutable(
    cc~ : String,
    include_dir~ : String,
    link_c~ : String,
    runtime_objs~ : Array[String], // the compiled runtime objects, linked in order
    moonbitrun_o~ : String?, //       `<lib>/libmoonbitrun.o` (prebuilt runtime),
    //                                linked FIRST; `None` for msvc

    stub_libs~ : Array[String],
    extra_objs~ : Array[String],
    libs~ : Array[String],
    cc_flags~ : Array[String],
    cc_link_flags~ : Array[String],
    link_flags~ : Array[String], //  module `link-flags`, appended to the cc link
    //                               (the native final-link site)
    cc_kind~ : String, //            cache identity only (see `BuildRuntime`)
    debug_info~ : Bool, //           emit native debug info (`/Z7` / `-g`)
    debug_mode~ : Bool, //           debug profile optimization (`/Od` / `-Og`)
    gen_dsym~ : Bool //              run `dsymutil` after the link to emit `<exe>.dSYM`
    //                               (macOS debug clang link; the driver does not
    //                               reliably auto-run it). Declares the dSYM outputs.
  )
}

///|
/// The build-wide environment, uniform across every action in one `Plan`:
/// the backend (`target`), the build `mode`, and the compiler version. NOT stored
/// per-action (that would duplicate it across the whole plan) — it lives once on
/// the `Plan`, and the engine (rebuilder + executor) captures it at construction.
/// Folded into each action's cache digest; `moonc_version` only for moonc actions.
pub(all) struct BuildEnv {
  target : String // backend: "wasm-gc"
  mode : String // "debug" / "release"
  moonc_version : String // `moonc -v` (cache identity for moonc actions)
  error_format : String // moonc `-error-format` (human/json); diagnostic-only, NOT in the digest
  debug_symbols : Bool // emit `-g`/`-source-map` (inverse of `--strip`); in the moonc digest
  diag : DiagOptions // diagnostic capture/render options; diagnostic-only, NOT in the digest
}

///|
/// How `moon` post-processes the compiler's diagnostics (upstream's
/// `--output-json` / `--no-render` / `--diagnostic-limit` / `--render-no-loc`).
/// When `capture` is set, moonc is run with `-error-format json` and its stderr is
/// redirected to a `<output>.diag` file (via `ExecTo`); `realize` collects those,
/// then renders them honoring `json` / `no_loc` / `limit`. When `capture` is false
/// the compiler's diagnostics stream straight through (mymoon's default), so the
/// other fields are inert.
pub(all) struct DiagOptions {
  capture : Bool //   redirect + collect + render (set by `--diagnostic-limit` / `--render-no-loc` / `--explain`)
  json : Bool //      render as JSON lines (`--output-json`) vs human
  no_loc : Bool //    omit the `path:loc` prefix (`--render-no-loc`)
  limit : Int? //     show at most N diagnostics, then a `… N more` line (`--diagnostic-limit`)
  explain : Bool //   after each diagnostic, append its bundled doc (`moon check --explain`)
}

///|
/// The inert default: no capture, stream the compiler's diagnostics as-is.
pub fn DiagOptions::none() -> DiagOptions {
  { capture: false, json: false, no_loc: false, limit: None, explain: false }
}

///|
/// One build step = one command. A node in the build graph.
///
/// `inputs` and `outputs` are artifact paths: dependency edges are expressed in
/// terms of FILES, not in terms of commands. The scheduler resolves each input
/// artifact through an `artifact -> producer Action` map and waits for that
/// producer before running this action.
///
/// `primary_output` is still required even though `outputs` lists every produced
/// artifact. It is the stable action identity used as the action-map key, the
/// default build target, and the representative path for diagnostics/progress.
/// Some commands produce multiple artifacts atomically (for example
/// `moonc build-package` emits both `.core` and `.mi`); those artifacts all live
/// in `outputs`, but they must not become separate runnable actions.
///
/// The build-wide environment (target/mode/toolchain) is NOT here — it is uniform
/// across the plan, so it lives on [`BuildEnv`].
pub(all) struct Action {
  primary_output : String
  outputs : Array[String]
  inputs : Array[String] // scheduling (dependency edges) + digest (content hashing)
  spec : ActionSpec // structured step description: rendered to a command + derives identity
}

///|
/// The action's rule tag (derived from its spec) — used for display/grouping and
/// as part of the cache identity.
pub fn ActionSpec::rule(self : ActionSpec) -> String {
  match self {
    Compile(check~, ..) => if check { "check" } else { "build-package" }
    BuildInterface(..) => "build-interface"
    LinkCore(..) => "link-core"
    BundleCore(..) => "bundle-core"
    Prebuild(..) => "pre-build"
    GenerateTestDriver(..) => "generate-test-driver"
    BuildRuntime(..) => "build-runtime"
    BuildCStub(..) => "build-c-stub"
    BuildZigStub(..) => "build-zig-stub"
    TranslateC(..) => "translate-c"
    BuildObjcStub(..) => "build-objc-stub"
    ArchiveCStubs(..) => "archive-c-stubs"
    MakeExecutable(..) => "make-executable"
  }
}

///|
pub fn Action::rule(self : Action) -> String {
  self.spec.rule()
}

///|
/// Whether this spec must be re-run every build rather than cached. Kept as a
/// semantic hook instead of hard-coding rule names in the rebuilder.
pub fn ActionSpec::always_run(self : ActionSpec) -> Bool {
  match self {
    _ => false
  }
}

///|
/// Diagnostic flags are usually output-neutral, but `@...` warn/alert specs
/// promote diagnostics to hard errors. Those change pass/fail semantics and must
/// bypass the pure mtime no-op path, which otherwise cannot see command changes.
pub fn ActionSpec::promotes_diagnostics(self : ActionSpec) -> Bool {
  match self {
    Compile(warn_list~, alert_list~, ..) =>
      option_contains_at(warn_list) || option_contains_at(alert_list)
    _ => false
  }
}

///|
fn option_contains_at(s : String?) -> Bool {
  match s {
    Some(v) => v.split_once("@") is Some(_)
    None => false
  }
}

///|
/// Whether this spec actually invokes `moonc` (so the compiler version belongs in
/// its cache identity). Only `Compile` (build-package / check) and `LinkCore` do —
/// the native `cc`/`ar` steps and the test-driver step run OTHER tools, and their
/// dependence on moonc is already captured by content-hashing the moonc-emitted
/// inputs (the `.c` / `.core` they consume).  The
/// rebuilder asks THIS rather than naming kinds, so the cache stays spec-agnostic.
pub fn ActionSpec::uses_moonc(self : ActionSpec) -> Bool {
  self is (Compile(..) | LinkCore(..) | BuildInterface(..) | BundleCore(..))
}

///|
/// The spec's PATH-FREE semantic identity: a canonical list of string tags that
/// becomes one leg of the action's cache digest (alongside `target`/`mode`, the
/// `moonc_version` for moonc actions, and every input's content hash).
///
/// It exists to distinguish actions that produce DIFFERENT output for reasons the
/// other legs miss. Input *content* is covered by hashing `inputs`; toolchain and
/// backend by `target`/`mode`/`moonc_version`. What's left are the path-free
/// SEMANTIC switches — `check` vs `build-package`, `fqn`, `is_main`, std on/off,
/// `test_kind`, `coverage`, and each import's ALIAS — which change the rendered
/// command (hence the output) but are NOT in the input bytes. Example: the same
/// source compiled with `coverage` on vs off has identical inputs yet different
/// output; `cov=true`/`cov=false` here keeps their cache keys apart.
///
/// The match deliberately SELECTS those fields and drops the rest via `..`: the
/// path fields (`sources`, `pkg_root`, dep `.mi` paths, cc paths) are excluded on
/// purpose — their content is already hashed via `inputs`, so the path itself is a
/// mere execution detail, and keeping absolute (machine-specific) paths OUT is
/// what makes the digest reproducible across machines/checkouts. Hence a dep keeps
/// its import ALIAS (`i=foo`, semantic) but NOT its `.mi` path.
pub fn ActionSpec::identity(self : ActionSpec) -> Array[String] {
  match self {
    Compile(
      check~,
      fqn~,
      is_main~,
      std_bundle~,
      deps~,
      std_imports~,
      test_kind~,
      coverage~,
      value_tracing~,
      virtual_impl~,
      no_mi~,
      all_pkgs~,
      compile_flags~,
      warn_list~,
      alert_list~,
      ..
    ) => {
      let t = [
        if check {
          "check"
        } else {
          "build-package"
        },
        "pkg=" + fqn,
        "main=" + is_main.to_string(),
        "std=" + (std_bundle is Some(_)).to_string(),
        "test=" +
        (match test_kind {
          Some(k) => k.name()
          None => "no"
        }),
        "cov=" + coverage.to_string(),
        "vtrace=" + value_tracing.to_string(),
        "nomi=" + no_mi.to_string(),
      ]
      // Workspace mode changes what moonc can resolve (lazy `.mi` loading); the
      // listing's CONTENT is covered by the inputs (the transitive `.mi`s join
      // them), so only the path-free presence bit goes here.
      if all_pkgs is Some(_) {
        t.push("allpkgs")
      }
      match virtual_impl {
        Some(vi) =>
          t.push("vimpl=" + vi.pkg_name + ":" + vi.is_impl.to_string())
        None => ()
      }
      for d in deps {
        t.push("i=" + d.import_alias)
      }
      for s in std_imports {
        t.push("si=" + s.sub + ":" + s.import_alias)
      }
      // Module `compile-flags` change the emitted `.core` (e.g. `-O2`, `-D`).
      for f in compile_flags {
        t.push("cflag=" + f)
      }
      // The warn-list is diagnostic-only and normally stays OUT of the identity —
      // EXCEPT for error-promotions (`@…`, e.g. `--deny-warn`'s `@a`), which turn
      // warnings into hard errors and so change the action's pass/fail outcome.
      // Those MUST be in the identity, or a prior non-promoting build cache-HITs
      // and the promotion never runs.
      match warn_list {
        Some(w) => if w.split_once("@") is Some(_) { t.push("werror=" + w) }
        None => ()
      }
      // Same rule for the alert-list: a `@…` promotion (e.g. `alert-list: "@deprecated"`)
      // turns an alert into a hard error, changing the action's pass/fail outcome, so it
      // MUST be in the identity — else a prior non-promoting build cache-HITs and the
      // deny never runs. (Plain non-promoting alerts stay out: diagnostic-only.)
      match alert_list {
        Some(a) => if a.split_once("@") is Some(_) { t.push("aerror=" + a) }
        None => ()
      }
      t
    }
    BuildInterface(fqn~, std_bundle~, deps~, ..) => {
      let t = [
        "build-interface",
        "pkg=" + fqn,
        "std=" + (std_bundle is Some(_)).to_string(),
      ]
      for d in deps {
        t.push("i=" + d.import_alias)
      }
      t
    }
    LinkCore(
      main~,
      std_bundle~,
      test_mode~,
      exported_functions~,
      js_format~,
      wasm_opts~,
      link_flags~,
      native_target~,
      output_wat~,
      ..
    ) => {
      let t = [
        "link-core",
        "main=" + main,
        "std=" + (std_bundle is Some(_)).to_string(),
        "test=" + test_mode.to_string(),
      ]
      // The "new native" target triple changes the linked artifact (a `.o`, with a
      // different `-target`), so it must distinguish cache entries from plain native.
      match native_target {
        Some(triple) => t.push("nativetgt=" + triple)
        None => ()
      }
      // Link-config switches are path-free and change the artifact: an export
      // list, a js module format, or a wasm memory layout each produce different
      // output from identical `.core` inputs — so they all join the identity.
      for e in exported_functions {
        t.push("export=" + e)
      }
      match js_format {
        Some(f) => t.push("jsfmt=" + f)
        None => ()
      }
      match wasm_opts {
        Some(w) => {
          match w.export_memory_name {
            Some(n) => t.push("memname=" + n)
            None => ()
          }
          match w.import_memory {
            Some((m, n)) => t.push("memimport=" + m + ":" + n)
            None => ()
          }
          match w.memory_limits {
            Some((mn, mx)) => t.push("memlim=\{mn}:\{mx}")
            None => ()
          }
          if w.shared_memory {
            t.push("shared-memory")
          }
          match w.heap_start_address {
            Some(a) => t.push("heap=\{a}")
            None => ()
          }
          if w.use_js_builtin_string {
            t.push("js-builtin-string")
          }
          match w.imported_string_constants {
            Some(ns) => t.push("strconst=" + ns)
            None => ()
          }
          for f in w.flags {
            t.push("flag=" + f)
          }
        }
        None => ()
      }
      for f in link_flags {
        t.push("lflag=" + f)
      }
      // `--output-wat` changes the artifact FORMAT (text `.wat` vs binary `.wasm`)
      // from identical `.core` inputs; the output path is excluded from the identity,
      // so this bit must be here to keep the two builds' cache entries distinct.
      if output_wat {
        t.push("output-wat")
      }
      t
    }
    // The bundle's identity is fully captured elsewhere: the `.core` inputs are
    // content-hashed (in order), and the backend by `BuildEnv::target`.
    BundleCore(..) => ["bundle-core"]
    Prebuild(command~, ..) => ["pre-build", "cmd=" + command]
    GenerateTestDriver(
      kind~,
      test_sources~,
      doctest_only~,
      pkg_name~,
      coverage~,
      bench~,
      max_concurrent_tests~,
      ..
    ) => {
      let t = [
        "generate-test-driver",
        "driver-cache-v3",
        "kind=" + kind.name(),
        "pkg=" + pkg_name,
        "cov=" + coverage.to_string(),
        "bench=" + bench.to_string(),
      ]
      match max_concurrent_tests {
        Some(n) => t.push("maxtests=\{n}")
        None => ()
      }
      for f in test_sources {
        t.push("testsrc=" + f)
      }
      for f in doctest_only {
        t.push("doctest=" + f)
      }
      t
    }
    // `cc=<kind>` distinguishes gcc/clang/tcc/msvc so their incompatible objects
    // don't alias in the CAS; ArchiveCStubs needs none (its `.o` inputs are already
    // content-hashed, carrying the distinction down from BuildCStub).
    BuildRuntime(cc_kind~, simdutf~, ..) =>
      ["build-runtime", "cc=" + cc_kind, "simdutf=\{simdutf}"]
    BuildCStub(cc_flags~, cc_kind~, ..) => {
      let t = ["build-c-stub", "cc=" + cc_kind]
      for f in cc_flags {
        t.push("flag=" + f)
      }
      t
    }
    // ObjC vs ObjC++ produce incompatible objects (`-x objective-c[++]`), so `cpp`
    // joins the identity alongside cc-kind + flags (cf. BuildCStub).
    BuildObjcStub(cc_flags~, cc_kind~, cpp~, ..) => {
      let t = ["build-objc-stub", "cc=" + cc_kind, "cpp=\{cpp}"]
      for f in cc_flags {
        t.push("flag=" + f)
      }
      t
    }
    // The `target` triple DOES change the object (ABI / std platform half / which
    // compiler-rt + stack-probe builtins are emitted), so it MUST join the identity —
    // otherwise a `x86_64-windows-msvc` object is served from a cache entry built for
    // the host (or a different zig), the exact unsoundness that masks a stub rebuild.
    // The zig driver + include_dir stay out (paths/execution detail); the stub source
    // is already hashed via the action inputs (like ArchiveCStubs).
    BuildZigStub(target~, ..) =>
      [
        "build-zig-stub",
        "target=" +
        (match target {
          Some(t) => t
          None => "host"
        }),
      ]
    // `header` disambiguates two TranslateC actions in one package (their outputs
    // differ but the digest must too, since the header is not a tracked input). The
    // zig driver + include_dir are paths (execution detail), excluded like the rest.
    TranslateC(header~, ..) => ["translate-c", "header=" + header]
    ArchiveCStubs(..) => ["archive-c-stubs"]
    MakeExecutable(cc_flags~, cc_link_flags~, link_flags~, cc_kind~, ..) => {
      let t = ["make-executable", "cc=" + cc_kind]
      for f in cc_flags {
        t.push("flag=" + f)
      }
      for f in cc_link_flags {
        t.push("lflag=" + f)
      }
      for f in link_flags {
        t.push("mlflag=" + f)
      }
      t
    }
  }
}

///|
/// A command to execute, decoupled from any shell. This is the first-principles
/// unit the bare executor runs:
///
/// - `Exec` — a program + argv vector, spawned DIRECTLY (no shell, so no quoting
///   pitfalls and no `/bin/sh`/`cmd.exe` dependency). `argv[0]` is the program.
///   `cwd` (if set) is the working directory to run it in. This is the default.
/// - `Shell` — an escape hatch for user-authored pre-build scripts that genuinely
///   need shell features; run under the platform shell. `cwd` is execution-only;
///   [`Command::render`] keeps the user-authored command text.
pub(all) enum Command {
  Exec(argv~ : Array[String], cwd~ : String?)
  /// Like `Exec` but the child's stdout(+stderr) is redirected to `stdout` (the
  /// file is created/truncated). For tools that emit their result to stdout with no
  /// output-file flag — currently `zig translate-c`. Integrates with the same
  /// spawn+`wait_any` pool as `Exec` (each child writes its own file). On success
  /// `translate-c` writes nothing to stderr, so the captured file is the clean `.zig`.
  ExecTo(argv~ : Array[String], stdout~ : String)
  Shell(command~ : String, cwd~ : String?)
}

///|
/// Render the command as a POSIX-shell string (debug/log/test use). NOT the
/// execution path — the executor runs `Exec` via direct argv spawn. Kept
/// byte-compatible with the historical `command()` output.
pub fn Command::render(self : Command) -> String {
  match self {
    Exec(argv~, ..) => argv.join(" ")
    ExecTo(argv~, stdout~) => argv.join(" ") + " > " + stdout
    Shell(command~, ..) => command
  }
}

// An action fails: the command ended with a non-zero exit code. A failure is **not cached**
// (otherwise it would pass a bad output off as a success), and it interrupts the rest of the build upward.

///|
pub(all) suberror BuildError {
  ActionFailed(output~ : String, code~ : Int)
  /// The command exited 0 but a DECLARED output is absent — a build-plan
  /// bug (a byproduct the command does not actually emit was declared, or one it
  /// does emit was named wrong). Raised loudly rather than silently caching an
  /// empty file, which would only surface much later as a corrupt warm-cache HIT.
  MissingOutput(action~ : String, missing~ : String)
}

// Rebuilder is split into three things, so a parallel scheduler can batch-concurrent the "execute" step:
//   try_hit —— decision: on a cache hit, restore the output and return true (no execution needed); otherwise false.
//   commit  —— commit: the command has run with a given exit code; on success write the cache, on failure raise.
//   resolve —— serial composition (decide → execute → commit): a single-call convenience for a serial
//              caller. The shipping scheduler (ParallelTopological) uses try_hit/commit directly; resolve
//              is kept as a tested primitive (see rebuilders_wbtest) for any future serial driver.

///|
pub(open) trait Rebuilder {
  async fn try_hit(Self, Action) -> Bool
  async fn try_hit_many(Self, Array[Action]) -> Array[Bool]
  async fn commit(Self, Action, Int) -> Unit
  async fn resolve(Self, Action, async () -> Int) -> Unit
}

// Execution strategy `Executor = (Action) -> Command`: given an Action, **render** the
// structured command finally to be run (an argv vector, not a shell string). The default
// implementation is `@executor.render_command` (the bare strategy — it lives in the
// `executor` package, NOT here, so `core` stays target-agnostic); another backend can
// render the same spec its own way. The isolation boundary is derived from the Action's
// inputs/output, and rendering vs. "when/whether to run" is decided by the scheduler.
// First principle: a command is argv, not a shell string — the scheduler spawns argv
// directly, and quote-escaping happens only at the Windows CreateProcess boundary.

///|
pub type Executor = (Action) -> Command

///|
pub(open) trait Scheduler {
  async fn run(Self, Map[String, Action], Array[String], &Rebuilder, Executor) -> Int
}

///|
pub(open) trait Backend {
  async fn realize(Self, Map[String, Action], Array[String]) -> Int
}
