// The native C-build action builders, reached only when `cfg.backend` is
// `Native(Some(nc))`

///|
fn path_stem(path : String) -> String {
  let base = @posix.Path::basename(path).to_owned()
  match base.rev_split_once(".") {
    Some((stem, _)) => stem.to_owned()
    None => base
  }
}

///|
/// Archive the `.o` stubs for a package.
fn archive_path(cfg : BuildConfig, fqn : String) -> String {
  @posix.Path::join(package_dir(cfg, fqn), "lib" + artifact_name(fqn) + ".a").0
}

///|
/// `cc`-compile the toolchain runtime sources into `.o` objects — one action
/// per source. The legacy monolithic layout keeps the historical single
/// `runtime.o`; a split runtime (`<root>/lib/runtime/*.c`) mirrors upstream's
/// per-source `runtime-<stem>.o`.
fn runtime_actions(
  cfg : BuildConfig,
  nc : NativeToolchain,
) -> Array[@core.Action] {
  // simdutf is decided HERE, not in the renderer, so the `-DMOONBIT_USE_SIMDUTF`
  // define and `NativeToolchain::extra_objs`' prebuilt objects come from one
  // decision and cannot disagree.
  let split = nc.has_split_runtime()
  let simdutf = !split
  let acts : Array[@core.Action] = []
  for src in nc.runtime_sources() {
    let out = if split {
      cfg.out_dir + "/runtime-" + path_stem(src) + ".o"
    } else {
      cfg.out_dir + "/runtime.o"
    }
    acts.push({
      primary_output: out,
      outputs: [out],
      inputs: [src],
      spec: @core.BuildRuntime(
        cc=nc.cc,
        include_dir=nc.include_dir(),
        runtime_c=src,
        simdutf~,
      ),
    })
  }
  acts
}

///|
/// The runtime objects a native link consumes, in plan order.
fn runtime_objects(cfg : BuildConfig, nc : NativeToolchain) -> Array[String] {
  let objs : Array[String] = []
  for act in runtime_actions(cfg, nc) {
    objs.push(act.primary_output)
  }
  objs
}

///|
/// `cc`-compile one C stub of a package_name into a `.o`. The OWNING package's
/// `link.native.stub-cc` / `stub-cc-flags` (if any) override the toolchain cc /
/// add flags — moon reads the stub overrides off the stub's own package, not
/// the link root.
fn cstub_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  stub : String,
  native_link : @config.NativeLinkConfig?,
) -> @core.Action {
  let out = @posix.Path::join(package_dir(cfg, fqn), path_stem(stub)).0 + ".o"
  let cc = effective_stub_cc(nc, native_link)
  let cc_flags = split_words(native_link.bind(fn(n) { n.stub_cc_flags }))
  {
    primary_output: out,
    outputs: [out],
    inputs: [stub],
    spec: @core.BuildCStub(cc~, include_dir=nc.include_dir(), stub~, cc_flags~),
  }
}

///|
/// `clang` one Objective-C (`.m`) / Objective-C++ (`.mm`) stub of a package into a
/// `.o`, slotted into the same archive/link as a C stub. Honors the owning
/// package's `stub-cc`/`stub-cc-flags` like `cstub_action` (the effective cc must
/// be clang from the Darwin stdenv. `cpp`
/// selects ObjC++ for `.mm`.
fn objcstub_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  stub : String,
  native_link : @config.NativeLinkConfig?,
  cpp : Bool,
) -> @core.Action {
  let out = @posix.Path::join(package_dir(cfg, fqn), path_stem(stub)).0 + ".o"
  let cc = effective_stub_cc(nc, native_link)
  {
    primary_output: out,
    outputs: [out],
    inputs: [stub],
    spec: @core.BuildObjcStub(
      cc~,
      include_dir=nc.include_dir(),
      stub~,
      cc_flags=split_words(native_link.bind(fn(n) { n.stub_cc_flags })),
      cpp~,
    ),
  }
}

///|
/// The effective C compiler for a package's stubs: its `link.native.stub-cc`
/// override if present, else the toolchain `cc`. Shared by `cstub_action` and the
/// Objective-C stub rendering.
fn effective_stub_cc(
  nc : NativeToolchain,
  native_link : @config.NativeLinkConfig?,
) -> String {
  match native_link {
    Some(n) =>
      match n.stub_cc {
        Some(c) => c
        None => nc.cc
      }
    None => nc.cc
  }
}

///|
/// `zig build-obj` one `.zig` stub of a package into a `.o`, slotted into the same
/// archive/link as a C stub. Needs the toolchain's `zig` driver; the caller raises
/// `ZigToolchainMissing` when absent rather than passing `None` here. Stub-cc
/// overrides don't apply (zig isn't a cc); link-time libs still ride the owning
/// package's `stub-cc-link-flags`, collected in `build_plan` regardless of stub kind.
fn zigstub_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  stub : String,
  zig : String,
  modules : Array[(String, String)],
) -> @core.Action {
  let out = @posix.Path::join(package_dir(cfg, fqn), path_stem(stub)).0 + ".o"
  // Each translated module's `.zig` is a build input → its TranslateC action must
  // run first, and a re-translation re-builds this stub (digest picks it up).
  let inputs = [stub, ..modules.map(fn(m) { m.1 })]
  // Nix native builds use the host target for both C and Zig.
  let target : String? = None
  {
    primary_output: out,
    outputs: [out],
    inputs,
    spec: @core.BuildZigStub(
      zig~,
      include_dir=nc.include_dir(),
      stub~,
      modules~,
      target~,
    ),
  }
}

///|
/// Compile one native stub into a `.o`, dispatching by extension: `.zig` → `zig
/// build-obj`, `.m`/`.mm` → the Darwin C compiler, everything else → `cc`.
/// `zig_modules` are the package's translated C headers, when configured.
fn stub_object_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  stub : String,
  native_link : @config.NativeLinkConfig?,
  zig_modules : Array[(String, String)],
) -> @core.Action raise BuildPlanError {
  if stub.has_suffix(".zig") {
    let zig = match nc.zig {
      Some(z) => z
      None => raise ZigToolchainMissing(package_name=fqn, stub~)
    }
    zigstub_action(cfg, nc, fqn, stub, zig, zig_modules)
  } else if stub.has_suffix(".m") || stub.has_suffix(".mm") {
    objcstub_action(cfg, nc, fqn, stub, native_link, stub.has_suffix(".mm"))
  } else {
    cstub_action(cfg, nc, fqn, stub, native_link)
  }
}

///|
/// The Zig module name for a translate-c'd header: its stem with the directory and
/// trailing `.h`/`.hpp`/`.hh` removed (`moonbit.h` → `moonbit`). A stub then writes
/// `@import("moonbit")`.
fn zig_module_name(header : String) -> String {
  path_stem(header)
}

///|
/// `zig translate-c` one header (in the toolchain `include_dir`, e.g. `moonbit.h`)
/// into a Zig module file the package's `.zig` stubs `@import`. The header is NOT a
/// tracked input (it lives in the toolchain, not the package) — its identity rides
/// `header` in the spec; see `@core.TranslateC`. Returns the action plus the
/// `(module-name, output-path)` pair `zigstub_action` wires as a `-M` module.
fn translatec_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  header : String,
  zig : String,
) -> (@core.Action, (String, String)) {
  let name = zig_module_name(header)
  // Single `.zig` extension (not `.translated.zig`): a double dot confuses
  // stem/ext splitting. `_tc` keeps it visibly a translate-c product.
  let out = @posix.Path::join(package_dir(cfg, fqn), name + "_tc.zig").0
  let act : @core.Action = {
    primary_output: out,
    outputs: [out],
    inputs: [],
    spec: @core.TranslateC(zig~, include_dir=nc.include_dir(), header~),
  }
  (act, (name, out))
}

///|
/// Archive a package_name's compiled C stubs into `lib<pkg>.a` (or `<pkg>.lib`).
fn archive_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  fqn : String,
  objs : Array[String],
) -> @core.Action {
  let out = archive_path(cfg, fqn)
  {
    primary_output: out,
    outputs: [out],
    inputs: objs,
    spec: @core.ArchiveCStubs(ar=nc.ar, objs~),
  }
}

///|
/// `cc`-link the emitted `.c` + runtime + stub archives + toolchain objects/libs
/// into the final native executable. The LINK ROOT's `link.native.cc` /
/// `cc-flags` / `cc-link-flags` (if any) override the toolchain cc / add flags.
fn make_exec_action(
  cfg : BuildConfig,
  nc : NativeToolchain,
  main_fqn : String,
  link_c : String,
  runtime_objs : Array[String],
  stub_libs : Array[String],
  native_link : @config.NativeLinkConfig?,
  bin_name : String?,
  link_flags : Array[String],
  stub_link_flags : Array[String],
) -> @core.Action {
  let out = native_exe_path(cfg, main_fqn, bin_name)
  let extra_objs = nc.extra_objs()
  let libs = nc.libs()
  let moonbitrun_o = nc.moonbitrun_o()
  let inputs : Array[String] = [
    link_c, ..runtime_objs, ..stub_libs, ..extra_objs, ..libs,
  ]
  match moonbitrun_o {
    Some(o) => inputs.push(o)
    None => ()
  }
  let cc = match native_link {
    Some(n) =>
      match n.cc {
        Some(c) => c
        None => nc.cc
      }
    None => nc.cc
  }
  // The final link carries the LINK ROOT's `cc-link-flags` PLUS every stub-owning
  // package's `stub-cc-link-flags` (e.g. `-lssl` for an OpenSSL stub). Stub flags go
  // last, after the objects/archives that reference them (GNU ld resolves libs right
  // to left). Mirrors rust moon, which gathers each stub package's link flags.
  let cc_link_flags = split_words(native_link.bind(fn(n) { n.cc_link_flags }))
  for f in stub_link_flags {
    cc_link_flags.push(f)
  }
  {
    primary_output: out,
    outputs: [out],
    inputs,
    spec: @core.MakeExecutable(
      cc~,
      include_dir=nc.include_dir(),
      link_c~,
      runtime_objs~,
      moonbitrun_o~,
      stub_libs~,
      extra_objs~,
      libs~,
      cc_flags=split_words(native_link.bind(fn(n) { n.cc_flags })),
      cc_link_flags~,
      link_flags~,
    ),
  }
}
