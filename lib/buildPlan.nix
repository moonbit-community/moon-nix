# Evaluate a checked-in planner JSON without running MoonBit during evaluation.
{ pkgs, toolchain }:
{
  plan,
  sources,
  name ? "moon-nix-project",
  nativeBuildInputs ? [ ],
}:
let
  inherit (pkgs) lib;
  data = if builtins.isAttrs plan then plan else lib.importJSON plan;
  validOutput =
    path: lib.hasPrefix "@build@/" path && !(builtins.elem ".." (lib.splitString "/" path));
  outputs = lib.concatMap (action: action.outputs) data.actions;
  valid =
    data.schemaVersion == 1
    && data.sourceCount == builtins.length sources
    && builtins.length outputs == builtins.length (lib.unique outputs)
    && lib.all validOutput outputs
    && lib.all (action: builtins.elem action.id action.outputs) data.actions
    && lib.all (root: builtins.elem root outputs) data.roots
    && lib.all (
      action:
      lib.all (input: !(lib.hasPrefix "@build@/" input) || builtins.elem input outputs) action.inputs
    ) data.actions
    && (
      data.target != "native"
      || data.platform == (if pkgs.stdenv.hostPlatform.isDarwin then "macos" else "linux")
    );
  producers = builtins.listToAttrs (
    lib.concatMap (
      action:
      map (output: {
        name = output;
        value = action.id;
      }) action.outputs
    ) data.actions
  );
  relative = lib.removePrefix "@build@/";
  sourceMap = builtins.listToAttrs (
    lib.imap0 (i: source: {
      name = "@src${toString i}@";
      value = "${source}";
    }) sources
  );
  makeAction =
    action:
    let
      # Include the transitive interfaces used by moonc's -all-pkgs lookup.
      closure = lib.genericClosure {
        startSet = [ { key = action.id; } ];
        operator =
          item:
          map (input: { key = producers.${input}; }) (
            builtins.filter (
              input: producers ? ${input} && producers.${input} != item.key
            ) actionSpecs.${item.key}.inputs
          );
      };
      dependencies = map (item: item.key) (builtins.filter (item: item.key != action.id) closure);
      dependencyOutputs = builtins.filter (
        output: builtins.elem producers.${output} dependencies
      ) outputs;
      substitutions =
        (lib.filterAttrs (token: _: lib.hasInfix token (builtins.toJSON action)) sourceMap)
        // {
          "@toolchain@" = toString toolchain;
        }
        // builtins.listToAttrs (
          map (output: {
            name = output;
            value = "${actions.${producers.${output}}}/${relative output}";
          }) dependencyOutputs
        );
      config = pkgs.writeText "moon-nix-action.json" (
        builtins.toJSON {
          inherit action substitutions;
          packages = builtins.filter (entry: builtins.elem entry.artifact dependencyOutputs) data.packages;
        }
      );
    in
    pkgs.runCommand "moon-nix-${builtins.baseNameOf action.id}"
      {
        nativeBuildInputs = [
          toolchain
          pkgs.python3
          pkgs.stdenv.cc
          pkgs.binutils
        ]
        ++ nativeBuildInputs;
      }
      ''
        python ${./runAction.py} ${config}
      '';
  actionSpecs = builtins.listToAttrs (
    map (action: {
      name = action.id;
      value = action;
    }) data.actions
  );
  actions = builtins.listToAttrs (
    map (action: {
      name = action.id;
      value = makeAction action;
    }) data.actions
  );
  roots = map (root: "${actions.${producers.${root}}}/${relative root}") data.roots;
in
assert lib.assertMsg valid "moon-nix: invalid plan schema, source count, or output ownership";
pkgs.runCommand name
  {
    passthru = { inherit actions roots; };
  }
  (
    ''
      mkdir -p $out/bin
    ''
    + lib.concatMapStringsSep "\n" (root: ''
      ln -s ${lib.escapeShellArg root} $out/bin/${lib.escapeShellArg (builtins.baseNameOf root)}
    '') roots
  )
