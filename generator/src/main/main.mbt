///|
fn fail(message : String) -> Unit {
  @os.eprintln(message)
  @os.exit(1)
}

///|
fn render_nix(value : Json, indent : String) -> String {
  match value {
    Json::Null | Json::True | Json::False | Json::Number(_, ..) => value.stringify()
    Json::String(_) => value.stringify().replace_all(old="${", new="\\${")
    Json::Array(items) => {
      if items.is_empty() {
        "[ ]"
      } else {
        let child_indent = indent + "  "
        let rendered : Array[String] = []
        for item in items {
          rendered.push(child_indent + render_nix(item, child_indent))
        }
        "[\n" + rendered.join("\n") + "\n" + indent + "]"
      }
    }
    Json::Object(fields) => {
      if fields.is_empty() {
        "{ }"
      } else {
        let child_indent = indent + "  "
        let keys = fields.keys().to_array()
        keys.sort()
        let rendered : Array[String] = []
        for key in keys {
          rendered.push(
            child_indent + render_nix(key.to_json(), child_indent) + " = " +
            render_nix(fields[key], child_indent) + ";",
          )
        }
        "{\n" + rendered.join("\n") + "\n" + indent + "}"
      }
    }
  }
}

///|
fn main {
  try {
    export_plan()
  } catch {
    error => fail(error.to_string())
  }
}

///|
fn export_plan() -> Unit raise {
  let args = @os.args()
  guard args.length() >= 5 else {
    fail("usage: moon2nix ROOT MAIN_PACKAGE TARGET TOOLCHAIN [DEPENDENCY_ROOT ...]")
    return
  }
  let root = @os.realpath(args[1]).unwrap()
  let main = args[2]
  let target = args[3]
  guard target == "wasm-gc" || target == "native" || target == "js" else {
    fail("supported targets: wasm-gc, native, js")
    return
  }
  let toolchain = @os.realpath(args[4]).unwrap()
  let dirs = [root]
  for i in 5..<args.length() {
    dirs.push(@os.realpath(args[i]).unwrap())
  }
  let packages = @model.BuildDiscovery::from_discover_result(
    @discover.discover_modules(dirs),
  )
  // Opaque prebuild scripts run during planning. Reject them BEFORE
  // calling the planner, so exporting a plan never executes project commands.
  for pkg in packages.all_packages() {
    if pkg.module_prebuild is Some(_) || !pkg.prebuild.is_empty() {
      fail("prebuild is not supported by this exporter yet: " + pkg.fqn)
      return
    }
  }
  let deps = @pkg_solve.solve_without_tests(packages)
  let backend = if target == "native" {
    @build_plan.Native(Some({ cc: "cc", ar: "ar", root: toolchain, zig: None }))
  } else {
    @build_plan.Backend::parse(target)
  }
  let (status, version) = @os.capture_argv([toolchain + "/bin/moonc", "-v"])
  guard status == 0 else { fail("cannot read moonc version"); return }
  let cfg = @build_plan.build_config(
    backend, @os.Platform::host(), @build_plan.Release, "/__moon2nix_build",
    version, Some({ bundle: toolchain + "/lib/core/_build/" + target + "/release/bundle",
      core_root: toolchain + "/lib/core" }),
    false, false, None, false, None, false, None, false, true,
    @core.DiagOptions::none(), None, true, None,
  )
  let plan = @build_plan.build_plan(packages, deps, main, cfg)
  fn normalize(s : String) -> String {
    let mut result = s.replace(old="/__moon2nix_build", new="@build@")
    result = result.replace(old=toolchain, new="@toolchain@")
    // Dependencies can be nested under the root; replace the longest first.
    let indices : Array[Int] = []
    for i in 0..<dirs.length() { indices.push(i) }
    indices.sort_by(fn(a, b) { dirs[b].length().compare(dirs[a].length()) })
    for i in indices {
      result = result.replace(old=dirs[i], new="@src\{i}@")
    }
    result
  }
  let actions : Array[Json] = []
  let listing : Array[Json] = []
  let keys = plan.actions().keys().to_array()
  keys.sort()
  for key in keys {
    let action = plan.actions()[key]
    let fqn = match action.spec {
      @core.Compile(fqn~, ..) => Some(fqn)
      @core.BuildInterface(fqn~, ..) => Some(fqn)
      _ => None
    }
    if fqn is Some(fqn) {
      for output in action.outputs {
        if output.has_suffix(".mi") && !output.has_suffix("_sub.mi") {
          let parts = fqn.split("/").to_array()
          let module_name = if parts.length() >= 2 { parts[0].to_owned() + "/" + parts[1].to_owned() } else { fqn }
          let rel = if fqn.length() > module_name.length() { fqn[module_name.length() + 1:].to_owned() } else { "" }
          listing.push({ "root": module_name.to_json(), "rel": rel.to_json(), "artifact": normalize(output).to_json() })
        }
      }
    }
    let command : Json = match @executor.render_command(action, plan.env()) {
      @core.Exec(argv~, cwd~) => {
        "kind": "exec",
        "argv": argv.map(normalize).to_json(),
        "cwd": match cwd { Some(p) => normalize(p).to_json(); None => Json::null() },
      }
      @core.ExecTo(argv~, stdout~) => {
        "kind": "exec-to",
        "argv": argv.map(normalize).to_json(),
        "stdout": normalize(stdout).to_json(),
      }
      @core.Shell(..) => {
        fail("shell actions are not supported by the exporter")
        return
      }
    }
    actions.push({
      "id": normalize(action.primary_output).to_json(),
      "outputs": action.outputs.map(normalize).to_json(),
      "inputs": action.inputs.map(normalize).to_json(),
      "command": command,
    })
  }
  let result : Json = {
    "schemaVersion": 1,
    "target": target.to_json(),
    "platform": @os.Platform::host().tag().to_json(),
    "main": main.to_json(),
    "sourceCount": dirs.length().to_json(),
    "actions": actions.to_json(),
    "packages": listing.to_json(),
    "roots": plan.roots().map(normalize).to_json(),
  }
  println("# Generated by moon2nix. Do not edit.")
  println(render_nix(result, ""))
}
