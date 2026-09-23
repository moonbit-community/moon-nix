// Build-graph vocabulary shared by planning and command rendering.

///|
pub const MOONBIT_H : String = "moonbit.h"

///|
/// A project interface passed to moonc as `-i <mi>:<alias>`.
pub(all) struct MiDep {
  mi : String
  import_alias : String
}

///|
/// A standard-library interface resolved relative to the selected bundle.
pub(all) struct StdImport {
  sub : String
  last : String
  import_alias : String
}

///|
/// Compile against a virtual interface; foreign implementations also use `-impl-virtual`.
pub(all) struct VirtualImpl {
  mi : String
  pkg_name : String
  pkg_root : String
  is_impl : Bool
}

///|
/// Backend-specific link settings decoded from the package manifest.
pub(all) struct WasmLinkOpts {
  export_memory_name : String?
  import_memory : (String, String)?
  memory_limits : (Int, Int)?
  shared_memory : Bool
  heap_start_address : Int?
  use_js_builtin_string : Bool
  imported_string_constants : String?
  flags : Array[String]
}

///|
/// Structured build steps, rendered to commands after the dependency graph is lowered.
pub(all) enum ActionSpec {
  Compile(
    sources~ : Array[String],
    fqn~ : String,
    is_main~ : Bool,
    std_bundle~ : String?,
    deps~ : Array[MiDep],
    std_imports~ : Array[StdImport],
    pkg_root~ : String,
    workspace~ : String?,
    all_pkgs~ : String?,
    virtual_impl~ : VirtualImpl?,
    no_mi~ : Bool,
    warn_list~ : String?,
    alert_list~ : String?,
    compile_flags~ : Array[String]
  )
  BuildInterface(
    mbti~ : String,
    fqn~ : String,
    pkg_root~ : String,
    std_bundle~ : String?,
    deps~ : Array[MiDep]
  )
  LinkCore(
    std_bundle~ : String?,
    cores~ : Array[String],
    main~ : String,
    pkg_config~ : String?,
    pkg_sources~ : Array[(String, String)],
    std_core_root~ : String?,
    exported_functions~ : Array[String],
    js_format~ : String?,
    wasm_opts~ : WasmLinkOpts?,
    link_flags~ : Array[String]
  )
  BundleCore(cores~ : Array[String])
  Prebuild(
    command~ : String,
    pkg_root~ : String,
    module_root~ : String,
    fqn~ : String
  )
  BuildRuntime(
    cc~ : String,
    include_dir~ : String,
    runtime_c~ : String,
    simdutf~ : Bool,
    debug_info~ : Bool
  )
  BuildCStub(
    cc~ : String,
    include_dir~ : String,
    stub~ : String,
    cc_flags~ : Array[String],
    debug_info~ : Bool,
    debug_mode~ : Bool
  )
  BuildZigStub(
    zig~ : String,
    include_dir~ : String,
    stub~ : String,
    modules~ : Array[(String, String)],
    target~ : String?
  )
  TranslateC(zig~ : String, include_dir~ : String, header~ : String)
  BuildObjcStub(
    cc~ : String,
    include_dir~ : String,
    stub~ : String,
    cc_flags~ : Array[String],
    cpp~ : Bool,
    debug_info~ : Bool,
    debug_mode~ : Bool
  )
  ArchiveCStubs(ar~ : String, objs~ : Array[String])
  MakeExecutable(
    cc~ : String,
    include_dir~ : String,
    link_c~ : String,
    runtime_objs~ : Array[String],
    moonbitrun_o~ : String?,
    stub_libs~ : Array[String],
    extra_objs~ : Array[String],
    libs~ : Array[String],
    cc_flags~ : Array[String],
    cc_link_flags~ : Array[String],
    link_flags~ : Array[String],
    debug_info~ : Bool,
    debug_mode~ : Bool,
    gen_dsym~ : Bool
  )
}

///|
/// Build profile shared by all commands in a plan.
pub(all) struct BuildEnv {
  target : String
  mode : String
  debug_symbols : Bool
}

///|
/// One command may produce several artifacts atomically. `primary_output` is its
/// stable key; `inputs` and `outputs` describe the complete artifact dependencies.
pub(all) struct Action {
  primary_output : String
  outputs : Array[String]
  inputs : Array[String]
  spec : ActionSpec
}

///|
/// Preserve argv boundaries and working directories for the Nix runner.
/// `ExecTo` writes stdout to an artifact; `Shell` is reserved for shell commands.
pub(all) enum Command {
  Exec(argv~ : Array[String], cwd~ : String?)
  ExecTo(argv~ : Array[String], stdout~ : String)
  Shell(command~ : String, cwd~ : String?)
}
