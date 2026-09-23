{ pkgs }:
{
  name,
  kind,
  roots,
  actions,
  resolvedModules ? null,
}:
let
  inherit (pkgs) lib;
in
pkgs.runCommand name
  {
    passthru = {
      inherit actions;
      roots = map (root: root.artifact) roots;
    }
    // lib.optionalAttrs (resolvedModules != null) { inherit resolvedModules; };
  }
  (
    if kind == "bundle" then
      lib.concatMapStringsSep "\n" (
        root:
        let
          destination = lib.removePrefix "@build@/" root.path;
        in
        ''
          mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf destination)}
          ln -s ${lib.escapeShellArg root.artifact} "$out"/${lib.escapeShellArg destination}
        ''
      ) roots
    else
      ''
        mkdir -p $out/bin
      ''
      + lib.concatMapStringsSep "\n" (root: ''
        ln -s ${lib.escapeShellArg root.artifact} $out/bin/${lib.escapeShellArg (builtins.baseNameOf root.artifact)}
      '') roots
  )
