///|
/// Rendering of an action's command, as a single string. We never really execute it, kept ONLY for human consumption — logging and test assertions.
///
pub fn command(act : @core.Action, env : @core.BuildEnv) -> String {
  render_command(act, env).render()
}

///|
/// Render the spec into a structured [`@core.Command`] — the bare execution
/// strategy. The build-wide `env` (target/mode) is passed in, not read off the
/// action (Action no longer carries it). Callers wire this as the `@core.Executor`
/// by capturing env in a closure: `executor: fn(act) { render_command(act, env) }`.
///
/// In diagnostic-CAPTURE mode (`env.diag.capture`, set by `--diagnostic-limit` /
/// `--render-no-loc`) an `Exec` command is redirected to a `<output>.diag` file so
/// `realize` can collect + re-render the compiler's diagnostics. The compiler is
/// already asked for JSON (`env.error_format == "json"`). Existing `ExecTo` (zig
/// translate-c, whose stdout IS its result) and `Shell` (pre-build) are left alone.
pub fn render_command(
  act : @core.Action,
  env : @core.BuildEnv,
) -> @core.Command {
  let cmd = render_command_inner(act, env)
  guard env.diag.capture else { return cmd }
  match cmd {
    Exec(argv~, ..) => @core.ExecTo(argv~, stdout=act.primary_output + ".diag")
    other => other
  }
}

///|
/// The spec → command rendering (wrapped by [`render_command`] for diagnostic
/// capture).
fn render_command_inner(
  act : @core.Action,
  env : @core.BuildEnv,
) -> @core.Command {
  match act.spec {
    @core.Compile(
      check~,
      sources~,
      fqn~,
      is_main~,
      std_bundle~,
      deps~,
      std_imports~,
      pkg_root~,
      test_kind~,
      doctest_only~,
      workspace~,
      all_pkgs~,
      coverage~,
      value_tracing~,
      virtual_impl~,
      no_mi~,
      warn_list~,
      alert_list~,
      compile_flags~
    ) => {
      let parts = ["moonc", if check { "check" } else { "build-package" }]
      // `--error-format json`: ask moonc to emit JSON diagnostics (default human).
      // Diagnostic-only, so it is rendered from `env` and stays out of the digest.
      if env.error_format != "human" {
        parts.push("-error-format")
        parts.push(env.error_format)
      }
      for f in sources {
        parts.push(f)
      }
      // One `-doctest-only` flag PER file (moonc takes a single file each), NOT one
      // flag with many files — otherwise moonc reads the 2nd+ files as positional
      // sources and type-checks them in the external blackbox context.
      for f in doctest_only {
        parts.push("-doctest-only")
        parts.push(f)
      }
      parts.push("-o")
      parts.push(act.primary_output)
      parts.push("-pkg")
      parts.push(fqn)
      if is_main {
        parts.push("-is-main")
      }
      match std_bundle {
        Some(b) => {
          parts.push("-std-path")
          parts.push(b)
          // The coverage runtime `.mi` (precedes prelude, matching moon).
          if coverage {
            parts.push("-i")
            parts.push(b + "/coverage/coverage.mi:coverage")
          }
          parts.push("-i")
          parts.push(b + "/prelude/prelude.mi:prelude")
        }
        None => ()
      }
      for d in deps {
        parts.push("-i")
        parts.push(d.mi + ":" + d.import_alias)
      }
      match std_bundle {
        Some(b) =>
          for s in std_imports {
            parts.push("-i")
            parts.push(
              @pathx.join([b, s.sub, s.last]) + ".mi:" + s.import_alias,
            )
          }
        None => ()
      }
      parts.push("-pkg-sources")
      parts.push(fqn + ":" + pkg_root)
      // Virtual-package check: `-check-mi <interface.mi>` ties this build to the
      // virtual interface; `-impl-virtual` marks it as a foreign implementation
      // (vs a virtual package's own default). The virtual package's own
      // `-pkg-sources` is added too so moonc resolves its source locations.
      // NB `moonc check` accepts `-check-mi` but NOT `-impl-virtual` (only
      // `build-package` does); `-check-mi` alone makes check verify the impl
      // against the interface, so we suppress `-impl-virtual` when checking.
      match virtual_impl {
        Some(vi) => {
          parts.push("-check-mi")
          parts.push(vi.mi)
          if vi.is_impl && !check {
            parts.push("-impl-virtual")
          }
          parts.push("-pkg-sources")
          parts.push(vi.pkg_name + ":" + vi.pkg_root)
        }
        None => ()
      }
      parts.push("-target")
      parts.push(env.target)
      // Debug info (`-g` + source map for non-native) is gated on `debug_symbols`
      // (the inverse of `--strip`): default keeps it in debug / drops it in release,
      // but `--strip`/`--no-strip` override independently of the opt level. No
      // optimization (`-O0`) tracks the build MODE, not strip. `check` takes none of
      // these (moonc check rejects -g/-O0/-source-map — it never codegens). Order
      // is kept (`-g` before `-O0`) so the common debug rendering is unchanged.
      if !check {
        if env.debug_symbols {
          parts.push("-g")
        }
        if env.mode == "debug" {
          parts.push("-O0")
        }
        // Source maps only apply to wasm-gc / js; the native-family backends
        // (native C and llvm) codegen to objects and reject `-source-map`.
        if env.debug_symbols && env.target != "native" && env.target != "llvm" {
          parts.push("-source-map")
        }
      }
      if coverage {
        parts.push("-enable-coverage")
      }
      if value_tracing {
        parts.push("-enable-value-tracing")
      }
      match test_kind {
        Some(kind) =>
          match kind {
            @core.Whitebox => parts.push("-whitebox-test")
            @core.Blackbox => {
              parts.push("-blackbox-test")
              parts.push("-include-doctests")
            }
            @core.Internal => ()
          }
        None => ()
      }
      if test_kind is Some(_) && !check {
        parts.push("-test-mode")
      }
      // `-no-mi`: skip emitting the `.mi` byproduct — for test builds (their `.mi`
      // is never imported) and a virtual default-impl (whose `.mi` is owned by its
      // `build-interface`).
      if no_mi {
        parts.push("-no-mi")
      }
      match workspace {
        Some(w) => {
          parts.push("-workspace-path")
          parts.push(w)
        }
        None => ()
      }
      match all_pkgs {
        Some(p) => {
          parts.push("-all-pkgs")
          parts.push(p)
        }
        None => ()
      }
      // Diagnostic control: `-w <warn-list>` / `-alert <alert-list>`. moonc reads
      // these from a JSON `moon.pkg.json` itself but NOT from the DSL `moon.pkg`,
      // so passing them as flags makes both manifest formats behave identically.
      match warn_list {
        Some(w) => {
          parts.push("-w")
          parts.push(w)
        }
        None => ()
      }
      match alert_list {
        Some(a) => {
          parts.push("-alert")
          parts.push(a)
        }
        None => ()
      }
      // Module `compile-flags`, appended raw (e.g. `-O2`, `-D FOO`).
      for f in compile_flags {
        parts.push(f)
      }
      @core.Exec(argv=parts, cwd=None)
    }
    @core.BuildInterface(mbti~, fqn~, pkg_root~, std_bundle~, deps~) => {
      // `moonc build-interface <mbti> -o <mi> -i <dep>:<alias>… -pkg <fqn>
      //  -pkg-sources <fqn>:<root> -virtual [-std-path <bundle>]`
      let parts = ["moonc", "build-interface", mbti, "-o", act.primary_output]
      for d in deps {
        parts.push("-i")
        parts.push(d.mi + ":" + d.import_alias)
      }
      parts.push("-pkg")
      parts.push(fqn)
      parts.push("-pkg-sources")
      parts.push(fqn + ":" + pkg_root)
      parts.push("-virtual")
      match std_bundle {
        Some(b) => {
          parts.push("-std-path")
          parts.push(b)
        }
        None => ()
      }
      @core.Exec(argv=parts, cwd=None)
    }
    // `output_wat` is identity-only (the artifact format); the command emits `.wat`
    // via the `-o` path's extension, so it is not rendered as a flag here.
    @core.LinkCore(
      std_bundle~,
      cores~,
      main~,
      pkg_config~,
      pkg_sources~,
      std_core_root~,
      test_mode~,
      exported_functions~,
      js_format~,
      wasm_opts~,
      link_flags~,
      native_target~,
      ..
    ) => {
      let parts = ["moonc", "link-core"]
      match std_bundle {
        Some(b) => {
          parts.push(b + "/abort/abort.core")
          parts.push(b + "/core.core")
        }
        None => ()
      }
      for c in cores {
        parts.push(c)
      }
      parts.push("-main")
      parts.push(main)
      parts.push("-o")
      parts.push(act.primary_output)
      // `-pkg-config-path <main pkg moon.pkg.json>` (right after `-o`, matching
      // moon's flag order). moonc reads link config from it in ADDITION to the
      // explicit switches below — moon 0.9.3 passes both, so there is no
      // double-apply.
      match pkg_config {
        Some(p) => {
          parts.push("-pkg-config-path")
          parts.push(p)
        }
        None => ()
      }
      if test_mode {
        parts.push("-test-mode")
      }
      for ps in pkg_sources {
        parts.push("-pkg-sources")
        parts.push(ps.0 + ":" + ps.1)
      }
      match std_core_root {
        Some(r) => {
          parts.push("-pkg-sources")
          parts.push("moonbitlang/core:" + r)
        }
        None => ()
      }
      // Test mode: the driver entry points, as two args (`-exported_functions
      // a,b`). Manifest `exports` instead render in the `=`-joined single-arg
      // spelling below, after the debug flags — matching moon's flag order
      // (moonc accepts both spellings).
      if test_mode && exported_functions.length() > 0 {
        parts.push("-exported_functions")
        parts.push(exported_functions.join(","))
      }
      match js_format {
        Some(f) => {
          parts.push("-js-format")
          parts.push(f)
        }
        None => ()
      }
      parts.push("-target")
      // "New native": moonc lowers link-core straight to a `.o` when given the host
      // triple (`aarch64-apple-darwin` / …) instead of `-target native`. Only
      // link-core takes the triple — build-package still uses `env.target` (it emits
      // backend-neutral `.core`). `None` everywhere else → the plain backend flag.
      parts.push(native_target.unwrap_or(env.target))
      // Same split as build-package: `-g`/source-map track `debug_symbols`
      // (`--strip`/`--no-strip`), `-O0` tracks the build mode. Order preserved.
      if env.debug_symbols {
        parts.push("-g")
      }
      if env.mode == "debug" {
        parts.push("-O0")
      }
      // Source maps only apply to wasm-gc / js; the native-family backends
      // (native C and llvm) codegen to objects and reject `-source-map`.
      if env.debug_symbols && env.target != "native" && env.target != "llvm" {
        parts.push("-source-map")
      }
      if !test_mode && exported_functions.length() > 0 {
        parts.push("-exported_functions=" + exported_functions.join(","))
      }
      match wasm_opts {
        Some(w) => {
          match w.export_memory_name {
            Some(n) => {
              parts.push("-export-memory-name")
              parts.push(n)
            }
            None => ()
          }
          match w.import_memory {
            Some((m, n)) => {
              parts.push("-import-memory-module")
              parts.push(m)
              parts.push("-import-memory-name")
              parts.push(n)
            }
            None => ()
          }
          match w.memory_limits {
            Some((mn, mx)) => {
              parts.push("-memory-limits-min")
              parts.push("\{mn}")
              parts.push("-memory-limits-max")
              parts.push("\{mx}")
            }
            None => ()
          }
          if w.shared_memory {
            parts.push("-shared-memory")
          }
          match w.heap_start_address {
            Some(a) => {
              parts.push("-heap-start-address")
              parts.push("\{a}")
            }
            None => ()
          }
          // moon parses these two but never renders them (its users pass the raw
          // flags via `flags`); we render them — a deliberate mymoon delta.
          if w.use_js_builtin_string {
            parts.push("-use-js-builtin-string")
          }
          match w.imported_string_constants {
            Some(ns) => {
              parts.push("-imported-string-constants")
              parts.push(ns)
            }
            None => ()
          }
          for f in w.flags {
            parts.push(f)
          }
        }
        None => ()
      }
      // Module `link-flags`, appended raw (the wasm/js final-link site).
      for f in link_flags {
        parts.push(f)
      }
      // The linear-`wasm` backend links a WASI runtime — moon 0.9.3 passes `-wasi`
      // on every `wasm` (not `wasm-gc`) link-core. wasm-gc / js / native don't.
      if env.target == "wasm" {
        parts.push("-wasi")
      }
      @core.Exec(argv=parts, cwd=None)
    }
    @core.BundleCore(cores~) => {
      // `moonc bundle-core <core…> -o <out.core>` — inputs in topological order.
      let parts = ["moonc", "bundle-core"]
      for c in cores {
        parts.push(c)
      }
      parts.push("-o")
      parts.push(act.primary_output)
      @core.Exec(argv=parts, cwd=None)
    }
    @core.Prebuild(command~, module_root~, ..) =>
      @core.Shell(command~, cwd=Some(module_root))
    @core.GenerateTestDriver(
      kind~,
      test_sources~,
      doctest_only~,
      metadata~,
      pkg_name~,
      coverage~,
      bench~,
      max_concurrent_tests~
    ) => {
      let parts = [
        "moon",
        "generate-test-driver",
        "--output-driver",
        act.primary_output,
        "--output-metadata",
        metadata,
      ]
      for f in test_sources {
        parts.push(f)
      }
      parts.push("--target")
      parts.push(env.target)
      parts.push("--pkg-name")
      parts.push(pkg_name)
      if coverage {
        parts.push("--enable-coverage")
      }
      if bench {
        parts.push("--bench")
      }
      match max_concurrent_tests {
        Some(n) => {
          parts.push("--max-concurrent-tests")
          parts.push("\{n}")
        }
        None => ()
      }
      parts.push("--driver-kind")
      parts.push(kind.name())
      // Keep repeatable `--doctest-only` last: the local CLI parser stores it as a
      // variadic named arg, so following named flags would otherwise be consumed as
      // more doctest-only values.
      for f in doctest_only {
        parts.push("--doctest-only")
        parts.push(f)
      }
      @core.Exec(argv=parts, cwd=None)
    }
    // Native C-toolchain arms — the OS + compiler-kind (MSVC / gcc-style)
    // branching lives in `executor_native.mbt` (see `render_*` there).
    @core.BuildRuntime(cc~, include_dir~, runtime_c~, simdutf~, debug_info~, ..) =>
      render_build_runtime(
        act.primary_output,
        cc,
        include_dir,
        runtime_c,
        simdutf,
        debug_info,
      )
    @core.BuildCStub(
      cc~,
      include_dir~,
      stub~,
      cc_flags~,
      debug_info~,
      debug_mode~,
      ..
    ) =>
      render_build_cstub(
        act.primary_output,
        cc,
        include_dir,
        stub,
        cc_flags,
        debug_info,
        debug_mode,
      )
    @core.BuildZigStub(zig~, include_dir~, stub~, modules~, target~) =>
      render_build_zig_stub(
        act.primary_output,
        zig,
        include_dir,
        stub,
        modules,
        target,
      )
    @core.TranslateC(zig~, include_dir~, header~) =>
      render_translate_c(act.primary_output, zig, include_dir, header)
    @core.BuildObjcStub(
      cc~,
      include_dir~,
      stub~,
      cc_flags~,
      cpp~,
      debug_info~,
      debug_mode~,
      ..
    ) =>
      render_build_objc_stub(
        act.primary_output,
        cc,
        include_dir,
        stub,
        cc_flags,
        cpp,
        debug_info,
        debug_mode,
      )
    @core.ArchiveCStubs(ar~, objs~) =>
      render_archive_cstubs(act.primary_output, ar, objs)
    @core.MakeExecutable(
      cc~,
      include_dir~,
      link_c~,
      runtime_objs~,
      moonbitrun_o~,
      stub_libs~,
      extra_objs~,
      libs~,
      cc_flags~,
      cc_link_flags~,
      link_flags~,
      debug_info~,
      debug_mode~,
      gen_dsym~,
      ..
    ) =>
      render_make_executable(
        act.primary_output,
        cc,
        include_dir,
        link_c,
        runtime_objs,
        moonbitrun_o,
        stub_libs,
        extra_objs,
        libs,
        cc_flags,
        cc_link_flags,
        link_flags,
        debug_info,
        debug_mode,
        gen_dsym,
      )
  }
}
