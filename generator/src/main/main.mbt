///|
fn fail(message : String) -> Unit {
  @os.eprintln(message)
  @unix.exit(1)
}

///|
fn render_nix(value : Json, indent : String) -> String {
  match value {
    Json::Null | Json::True | Json::False | Json::Number(_, ..) =>
      value.stringify()
    Json::String(_) => value.stringify().replace_all(old="${", new="\\${")
    Json::Array(items) =>
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
    Json::Object(fields) =>
      if fields.is_empty() {
        "{ }"
      } else {
        let child_indent = indent + "  "
        let keys = fields.keys().to_array()
        keys.sort()
        let rendered : Array[String] = []
        for key in keys {
          rendered.push(
            child_indent +
            render_nix(key.to_json(), child_indent) +
            " = " +
            render_nix(fields[key], child_indent) +
            ";",
          )
        }
        "{\n" + rendered.join("\n") + "\n" + indent + "}"
      }
  }
}

///|
fn main {
  export_plan() catch {
    error => fail(error.to_string())
  }
}

///|
fn export_plan() -> Unit raise {
  let args = @unix.args()
  guard args.length() >= 5 else {
    fail(
      "usage: moon2nix ROOT MAIN_PACKAGE TARGET TOOLCHAIN [--registry-index INDEX_DIR] [DEPENDENCY_ROOT ...]\n       moon2nix bundle ROOT TARGET TOOLCHAIN [--registry-index INDEX_DIR] [DEPENDENCY_ROOT ...]",
    )
    return
  }
  let is_bundle = args[1] == "bundle"
  let root = @os.realpath(if is_bundle { args[2] } else { args[1] }).unwrap()
  let main = if is_bundle {
    let manifest = @parse.load_mod(root).unwrap()
    @config.decode_mod(manifest).name
  } else {
    args[2]
  }
  let target = args[3]
  guard target == "wasm-gc" || target == "native" || target == "js" else {
    fail("supported targets: wasm-gc, native, js")
    return
  }
  let toolchain = @os.realpath(args[4]).unwrap()
  let mut source_arg = 5
  let mut index_dir : String? = None
  if args.length() > 5 && args[5] == "--registry-index" {
    guard args.length() > 6 else {
      fail("--registry-index requires a directory")
      return
    }
    index_dir = @os.realpath(args[6])
    guard index_dir is Some(_) else {
      fail("registry index directory does not exist")
      return
    }
    source_arg = 7
  }
  let dirs = [root]
  for i in source_arg..<args.length() {
    dirs.push(@os.realpath(args[i]).unwrap())
  }
  let resolved = match index_dir {
    Some(path) => resolve_plan_sources(root, dirs, path)
    None => ResolvedPlanSources::{ metadata: Json::null(), edges: Map([]), }
  }
  let packages = @discover.discover_modules(dirs, module_edges=resolved.edges)
  // Opaque prebuild scripts run during planning. Reject them BEFORE
  // calling the planner, so exporting a plan never executes project commands.
  for pkg in packages.all_packages() {
    if pkg.module_prebuild is Some(_) || !pkg.prebuild.is_empty() {
      fail("prebuild is not supported by this exporter yet: " + pkg.fqn)
      return
    }
  }
  let deps = @pkg_solve.solve(packages)
  let backend = if target == "native" {
    @build_plan.Native(
      Some({ cc: "cc", ar: "ar", root: toolchain, zig: None, }),
    )
  } else {
    @build_plan.Backend::parse(target)
  }
  let cfg : @build_plan.BuildConfig = {
    backend,
    out_dir: "/__moon2nix_build",
    bundle_of: if is_bundle {
      Some(main)
    } else {
      None
    },
    std: if is_bundle && main == "moonbitlang/core" {
      None
    } else {
      Some({
        bundle: toolchain + "/lib/core/_build/" + target + "/release/bundle",
        core_root: toolchain + "/lib/core",
      })
    },
  }
  let plan = if is_bundle {
    @build_plan.bundle_plan(packages, deps, cfg)
  } else {
    @build_plan.build_plan(packages, deps, main, cfg)
  }
  fn normalize(s : String) -> String {
    let mut result = s.replace(old="/__moon2nix_build", new="@build@")
    // Source roots can also be inside the toolchain (when rebuilding core).
    // Normalize the longest path first across both sources and the toolchain.
    let paths = [..dirs, toolchain]
    let indices : Array[Int] = []
    for i in 0..<paths.length() {
      indices.push(i)
    }
    indices.sort_by(fn(a, b) { paths[b].length().compare(paths[a].length()) })
    for i in indices {
      let token = if i == dirs.length() { "@toolchain@" } else { "@src\{i}@" }
      result = result.replace(old=paths[i], new=token)
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
          let module_name = if parts.length() >= 2 {
            parts[0].to_owned() + "/" + parts[1].to_owned()
          } else {
            fqn
          }
          let rel = if fqn.length() > module_name.length() {
            fqn[module_name.length() + 1:].to_owned()
          } else {
            ""
          }
          listing.push({
            "root": module_name.to_json(),
            "rel": rel.to_json(),
            "artifact": normalize(output).to_json(),
          })
        }
      }
    }
    let command : Json = match @build_plan.render_command(action, plan.env()) {
      @core.Exec(argv~, cwd~) =>
        {
          "kind": "exec",
          "argv": argv.map(normalize).to_json(),
          "cwd": match cwd {
            Some(p) => normalize(p).to_json()
            None => Json::null()
          },
        }
      @core.ExecTo(argv~, stdout~) =>
        {
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
  let result : Map[String, Json] = {
    "schemaVersion": 1,
    "target": target.to_json(),
    "sourceCount": dirs.length().to_json(),
    "actions": actions.to_json(),
    "packages": listing.to_json(),
    "roots": plan.roots().map(normalize).to_json(),
  }
  if is_bundle {
    result["kind"] = "bundle".to_json()
    result["module"] = main.to_json()
  } else {
    result["main"] = main.to_json()
  }
  if index_dir is Some(_) {
    result["resolvedModules"] = resolved.metadata
  }
  println("# Generated by moon2nix. Do not edit.")
  println(render_nix(result.to_json(), ""))
}
