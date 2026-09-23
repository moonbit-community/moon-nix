///|
/// Render a structured build step into an argv or shell command.
pub fn render_command(
  act : @core.Action,
  env : @core.BuildEnv,
) -> @core.Command {
  match act.spec {
    @core.Compile(
      sources~,
      fqn~,
      is_main~,
      std_bundle~,
      deps~,
      std_imports~,
      pkg_root~,
      workspace~,
      all_pkgs~,
      virtual_impl~,
      no_mi~,
      warn_list~,
      alert_list~,
      compile_flags~
    ) => {
      let parts = ["moonc", "build-package"]
      for f in sources {
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
              @posix.Path::join(@posix.Path::join(b, s.sub), s.last).0 +
              ".mi:" +
              s.import_alias,
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
          if vi.is_impl {
            parts.push("-impl-virtual")
          }
          parts.push("-pkg-sources")
          parts.push(vi.pkg_name + ":" + vi.pkg_root)
        }
        None => ()
      }
      parts.push("-target")
      parts.push(env.target)
      // A virtual default implementation must not overwrite its interface action
      // output with another `.mi`.
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
    @core.LinkCore(
      std_bundle~,
      cores~,
      main~,
      pkg_config~,
      pkg_sources~,
      std_core_root~,
      exported_functions~,
      js_format~,
      wasm_opts~,
      link_flags~
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
      match js_format {
        Some(f) => {
          parts.push("-js-format")
          parts.push(f)
        }
        None => ()
      }
      parts.push("-target")
      parts.push(env.target)
      if exported_functions.length() > 0 {
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
    // Native C-toolchain command construction lives in `render_native.mbt`.
    @core.BuildRuntime(cc~, include_dir~, runtime_c~, simdutf~) =>
      render_build_runtime(
        act.primary_output,
        cc,
        include_dir,
        runtime_c,
        simdutf,
      )
    @core.BuildCStub(cc~, include_dir~, stub~, cc_flags~) =>
      render_build_cstub(act.primary_output, cc, include_dir, stub, cc_flags)
    @core.BuildZigStub(zig~, include_dir~, stub~, modules~) =>
      render_build_zig_stub(act.primary_output, zig, include_dir, stub, modules)
    @core.TranslateC(zig~, include_dir~, header~) =>
      render_translate_c(act.primary_output, zig, include_dir, header)
    @core.BuildObjcStub(cc~, include_dir~, stub~, cc_flags~, cpp~) =>
      render_build_objc_stub(
        act.primary_output,
        cc,
        include_dir,
        stub,
        cc_flags,
        cpp,
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
      link_flags~
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
      )
  }
}
