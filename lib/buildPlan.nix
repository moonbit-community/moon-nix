# Build the actions in a checked-in moon.nix plan.
{ pkgs, toolchain }:
{
  plan,
  sources,
  name ? "moon2nix-project",
  nativeBuildInputs ? [ ],
  # Additional derivation attributes for each action (flags, environment, dependencies).
  actionOverrides ? action: { },
  # Select the Nix C toolchain; for example pkgs.clangStdenv.
  stdenv ? pkgs.stdenv,
  # A standard-library bundle built by another buildPlan call. The compiler and
  # native runtime still come from toolchain; only the bundled core is replaced.
  stdlib ? null,
}:
let
  inherit (pkgs) lib;
  data = plan;
  kind = data.kind or "executable";
  validOutput =
    path: lib.hasPrefix "@build@/" path && !(builtins.elem ".." (lib.splitString "/" path));
  outputs = lib.concatMap (action: action.outputs) data.actions;
  valid =
    data.schemaVersion == 1
    && builtins.elem kind [
      "executable"
      "bundle"
    ]
    && data.sourceCount == builtins.length sources
    && builtins.length outputs == builtins.length (lib.unique outputs)
    && lib.all validOutput outputs
    && lib.all (action: builtins.elem action.id action.outputs) data.actions
    && lib.all (root: builtins.elem root outputs) data.roots
    && lib.all (
      action:
      lib.all (input: !(lib.hasPrefix "@build@/" input) || builtins.elem input outputs) action.inputs
    ) data.actions;
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
        (lib.filterAttrs (
          token: _:
          lib.any (value: lib.hasInfix token value) (
            action.inputs
            ++ action.outputs
            ++ action.command.argv
            ++ lib.optional ((action.command.cwd or null) != null) action.command.cwd
            ++ lib.optional (action.command ? stdout) action.command.stdout
          )
        ) sourceMap)
        // {
          "@toolchain@" = toString toolchain;
        }
        // lib.optionalAttrs (stdlib != null) {
          "@toolchain@/lib/core/_build/${data.target}/release/bundle" = toString stdlib;
        }
        // builtins.listToAttrs (
          map (output: {
            name = output;
            value = "${actions.${producers.${output}}}/${relative output}";
          }) dependencyOutputs
        );
      # Replace complete artifact paths before shorter directory placeholders.
      tokens = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
        builtins.attrNames substitutions
      );
      resolve = builtins.replaceStrings tokens (map (token: substitutions.${token}) tokens);
      shellTokens = tokens ++ [ "@build@" ];
      tokenPattern = "(" + lib.concatMapStringsSep "|" lib.escapeRegex shellTokens + ")";
      # Quote literal text and substituted paths separately; only $out expands
      # in the build shell. Substitution values are never scanned a second time.
      shellArg =
        value:
        lib.concatMapStrings (
          part:
          if builtins.isList part then
            if builtins.head part == "@build@" then
              ''"$out"''
            else
              lib.escapeShellArg substitutions.${builtins.head part}
          else
            lib.escapeShellArg part
        ) (builtins.split tokenPattern value);
      listing = pkgs.writeText "all_pkgs.json" (
        builtins.toJSON {
          packages = map (entry: entry // { artifact = resolve entry.artifact; }) (
            builtins.filter (entry: builtins.elem entry.artifact dependencyOutputs) data.packages
          );
        }
      );
      command = action.command;
      argv = lib.concatMapStringsSep " " shellArg command.argv;
      script =
        if command.kind == "exec" then
          lib.optionalString ((command.cwd or null) != null) "cd ${shellArg command.cwd}\n" + argv
        else if command.kind == "exec-to" then
          "${argv} > ${shellArg command.stdout}"
        else
          throw "moon2nix: unsupported command kind ${command.kind}";

    in
    pkgs.runCommandWith
      {
        inherit stdenv;
        name = "moon2nix-${builtins.baseNameOf action.id}";
        derivationArgs = {
          nativeBuildInputs = [
            toolchain
            pkgs.binutils
          ]
          ++ nativeBuildInputs;
        }
        // actionOverrides action;
      }
      ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n" (
          output: "mkdir -p ${shellArg (builtins.dirOf output)}"
        ) action.outputs}
        cp ${listing} "$out/all_pkgs.json"
        ${script}
        ${lib.concatMapStringsSep "\n" (output: "test -f ${shellArg output}") action.outputs}
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
assert lib.assertMsg valid "moon2nix: invalid plan schema, source count, or output ownership";
pkgs.runCommand name
  {
    passthru = { inherit actions roots; };
  }
  (
    if kind == "bundle" then
      lib.concatMapStringsSep "\n" (
        root:
        let
          destination = relative root;
          artifact = "${actions.${producers.${root}}}/${destination}";
        in
        ''
          mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf destination)}
          ln -s ${lib.escapeShellArg artifact} "$out"/${lib.escapeShellArg destination}
        ''
      ) data.roots
    else
      ''
        mkdir -p $out/bin
      ''
      + lib.concatMapStringsSep "\n" (root: ''
        ln -s ${lib.escapeShellArg root} $out/bin/${lib.escapeShellArg (builtins.baseNameOf root)}
      '') roots
  )
