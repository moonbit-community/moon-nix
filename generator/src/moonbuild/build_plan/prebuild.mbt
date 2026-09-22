// Pre-build codegen: lower each package_name's `pre-build` rules into always-run
// actions, with moon's variable substitution (`$input`/`$output`/`$pkg_dir`/
// `$mod_dir`) and built-in command rewriting (`:embed …`).

///|
/// Emit a `pre-build` action for each codegen rule of `pkg_id`, returning the
/// generated output paths (which become first-class compile inputs). The command
/// is expanded for `$input` / `$output` / `$pkg_dir`. Mirrors moonbuild's
/// `RunPrebuild` node.
fn emit_prebuild_actions(
  packages : @model.BuildDiscovery,
  pkg_id : @model.PackageId,
  actions : Map[String, @core.Action],
  mooncake_bin~ : String,
) -> Array[String] {
  let pkg = packages.get_package(pkg_id)
  let generated : Array[String] = []
  for rule in pkg.prebuild {
    let ins = rule.input.map(fn(p) { pkg.root_path + "/" + p })
    let outs = rule.output.map(fn(p) { pkg.root_path + "/" + p })
    // `:embed …` is moon's built-in embed codegen — shorthand for the toolchain's
    // `moon tool embed …` (toolchain `moon` is on the sandbox PATH).
    let command = resolve_windows_launcher(
      resolve_relative_argv0(
        rewrite_prebuild_builtins(
          expand_vars(
            rule.command,
            pkg.root_path,
            pkg.module_root,
            ins,
            outs,
            mooncake_bin~,
          ),
        ),
        pkg.module_root,
      ),
    )
    // Key the action by its first output; the full output set is cached/restored
    // together because the command produces it atomically.
    guard outs.length() > 0 else { continue }
    // Pre-build runs BARE on the host (no sandbox), so `$mod_dir/boot/*.cjs` and
    // any project-relative paths are just plain files on the real filesystem — no
    // binding needed. The action's inputs are the rule's declared `$input` files,
    // used only for scheduling (pre-build is always-run, so they never gate a
    // cache lookup); the generated outputs are content-hashed downstream by the
    // build-package that consumes them.
    let act : @core.Action = {
      primary_output: outs[0],
      outputs: outs.copy(),
      inputs: ins,
      spec: @core.Prebuild(
        command~,
        pkg_root=pkg.root_path,
        module_root=pkg.module_root,
        fqn=pkg.fqn,
      ),
    }
    actions[act.primary_output] = act
    for o in outs {
      generated.push(o)
    }
  }
  generated
}

///|
/// The ROOT module's `__moonbin__` launcher directory — where bin-deps install
/// their executables and where `$mooncake_bin` in a pre-build command expands to.
/// Derived from the root module (`ModuleId(0)`) source root; `""`-rooted fallback
/// if somehow no root-module package exists (no pre-build can run then anyway).
fn root_mooncake_bin(packages : @model.BuildDiscovery) -> String {
  let mut root = ""
  for pkg in packages.all_packages() {
    let @model.ModuleId(m) = pkg.module_id
    if m == 0 {
      root = pkg.module_root
      break
    }
  }
  root + "/.mooncakes/__moonbin__"
}

///|
/// Resolve a RELATIVE `argv[0]` against the module root, mirroring the stock rust
/// `moon` (build_plan/builders.rs): a pre-build command whose program is a
/// project-relative path like `.mooncakes/__moonbin__/<tool>` is made absolute by
/// prepending the module dir. We prefer this relative spelling over `$mooncake_bin`
/// in `moon.pkg` because the stock `moon` only applies its Windows launcher fixup
/// (resolve `<argv0>.ps1` + wrap in `powershell`) to a RELATIVE argv[0]; an
/// already-absolute `$mooncake_bin/<tool>` skips that path and fails on Windows
/// (`CreateProcessA` cannot run a `.ps1`). The resulting absolute command is
/// byte-identical to the old `$mooncake_bin` expansion, so execution is
/// unchanged. argv[0] tokens with no separator (`moon`,
/// `node`) or already absolute are left untouched.
fn resolve_relative_argv0(command : String, mod_dir : String) -> String {
  let (argv0, rest) = match command.split_once(" ") {
    Some((a, r)) => (a.to_owned(), " " + r.to_owned())
    None => (command, "")
  }
  let looks_like_path = argv0.split_once("/") is Some(_) ||
    argv0.split_once("\\") is Some(_)
  let is_absolute = argv0.has_prefix("/") || argv0.has_prefix("\\")
  if looks_like_path && !is_absolute {
    // Drop a leading `./` so the resolved path is clean (`<mod>/gendocs`, not
    // `<mod>/./gendocs`).
    let rel = match argv0.strip_prefix("./") {
      Some(v) => v.to_owned()
      None => argv0
    }
    mod_dir + "/" + rel + rest
  } else {
    command
  }
}

///|
/// Windows does not execute Unix-style extensionless launcher scripts. Rust moon
/// resolves a pre-build command's program token to the real launcher before
/// spawning it; do the same here for shell pre-builds so both `$mooncake_bin/foo`
/// and `$mod_dir/.mooncakes/.../foo` work when the installed file is `foo.cmd`,
/// `foo.exe`, `foo.bat`, or `foo.ps1`.
fn resolve_windows_launcher(command : String) -> String {
  guard @os.os_kind() is Windows else { return command }
  let (argv0, rest) = match command.split_once(" ") {
    Some((a, r)) => (a.to_owned(), " " + r.to_owned())
    None => (command, "")
  }
  let looks_like_path = argv0.split_once("/") is Some(_) ||
    argv0.split_once("\\") is Some(_)
  guard looks_like_path else { return command }
  if argv0.has_suffix(".ps1") && @os.exists(argv0) {
    return "powershell -NoProfile -ExecutionPolicy Bypass -File " + argv0 + rest
  }
  if (
      argv0.has_suffix(".cmd") ||
      argv0.has_suffix(".exe") ||
      argv0.has_suffix(".bat")
    ) &&
    @os.exists(argv0) {
    return command
  }
  for ext in [".cmd", ".exe", ".bat"] {
    let candidate = argv0 + ext
    if @os.exists(candidate) {
      return candidate + rest
    }
  }
  let ps1 = argv0 + ".ps1"
  if @os.exists(ps1) {
    "powershell -NoProfile -ExecutionPolicy Bypass -File " + ps1 + rest
  } else if @os.exists(argv0) {
    command
  } else {
    command
  }
}

///|
/// Rewrite moon's built-in pre-build commands into a runnable form: `:embed …`
/// → `moon tool embed …` (the toolchain `moon` is on the sandbox PATH).
fn rewrite_prebuild_builtins(command : String) -> String {
  match command.strip_prefix(":embed ") {
    Some(rest) => "moon tool embed " + rest.to_owned()
    None => command
  }
}

///|
/// Expand `$input` / `$output` / `$pkg_dir` in a pre-build command. `$input` and
/// `$output` become the space-joined file lists. A lone `$` is left as-is.
/// Mirrors moonbuild's pre-build variable substitution (minus the rule/mooncake
/// variables moon does not model yet).
fn expand_vars(
  command : String,
  pkg_dir : String,
  mod_dir : String,
  inputs : Array[String],
  outputs : Array[String],
  mooncake_bin~ : String,
) -> String {
  // `mooncake_bin` must precede `mod_dir` only by being a distinct token; the
  // matcher tries each name in order, and the names share no prefix, so order is
  // immaterial. `$mooncake_bin` → the `__moonbin__` launcher dir holding bin-deps.
  let vars : Array[(String, String)] = [
    ("output", outputs.join(" ")),
    ("input", inputs.join(" ")),
    ("mooncake_bin", mooncake_bin),
    ("pkg_dir", pkg_dir),
    ("mod_dir", mod_dir),
  ]
  let cs = command.to_array()
  let n = cs.length()
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    if cs[i] == '$' {
      let mut matched = false
      for v in vars {
        let (name, value) = v
        if matches_at(cs, i + 1, name) {
          sb.write_string(value)
          i = i + 1 + name.length()
          matched = true
          break
        }
      }
      if !matched {
        sb.write_char('$')
        i = i + 1
      }
    } else {
      sb.write_char(cs[i])
      i = i + 1
    }
  }
  sb.to_string()
}

///|
/// Whether `name` appears in `cs` starting at index `pos`.
fn matches_at(cs : Array[Char], pos : Int, name : String) -> Bool {
  let nm = name.to_array()
  if pos + nm.length() > cs.length() {
    return false
  }
  for k in 0..<nm.length() {
    if cs[pos + k] != nm[k] {
      return false
    }
  }
  true
}
