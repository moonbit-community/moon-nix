# Execute one action whose artifact dependencies are wired by generated moon.nix.
{ pkgs, toolchain }:
{
  action,
  sources,
  dependencies,
  packages,
  target,
  stdlib ? null,
  stdenv ? null,
  nativeBuildInputs ? [ ],
  actionOverrides ? action: { },
}:
let
  inherit (pkgs) lib;
  sourceMap = builtins.listToAttrs (
    lib.imap0 (i: source: {
      name = "@src${toString i}@";
      value = "${source}";
    }) sources
  );
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
      "@toolchain@/lib/core/_build/${target}/release/bundle" = toString stdlib;
    }
    // dependencies;
  tokens = lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
    builtins.attrNames substitutions
  );
  resolve = builtins.replaceStrings tokens (map (token: substitutions.${token}) tokens);
  shellTokens = tokens ++ [ "@build@" ];
  tokenPattern = "(" + lib.concatMapStringsSep "|" lib.escapeRegex shellTokens + ")";
  # Quote literal text and substituted paths separately; only $out expands.
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
      packages = map (entry: entry // { artifact = resolve entry.artifact; }) packages;
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
    stdenv = if stdenv == null then pkgs.stdenv else stdenv;
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
  ''
