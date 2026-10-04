# Registry checksums hash the published ZIP, not the unpacked tree. Reading
# manifests from this unpacking derivation requires IFD; no planner is executed.
{ pkgs }:
{
  downloadBase ? "https://download.mooncakes.io",
}:
module:
let
  inherit (pkgs) lib;
  fail = message: throw "moon-nix fetch: ${message}";
  entry = module.entry;
  checksum =
    entry.checksum or (fail "${module.name}@${module.version}: registry record has no checksum");
  url =
    entry.url or "${lib.removeSuffix "/" downloadBase}/user/${module.name}/${
      lib.replaceStrings [ "+" ] [ "%2B" ] module.version
    }.zip";
  archive = pkgs.fetchurl {
    inherit url;
    name = "moonbit-${lib.replaceStrings [ "/" ] [ "-" ] module.name}-${module.version}.zip";
    sha256 =
      if builtins.isString checksum && builtins.match "[0-9a-fA-F]{64}" checksum != null then
        lib.toLower checksum
      else
        fail "${module.name}@${module.version}: checksum must be a SHA-256 hex digest";
  };
in
if entry ? src then
  entry.src
else if entry ? url && entry ? narHash then
  (builtins.fetchTree {
    type = "tarball";
    inherit (entry) url narHash;
  }).outPath
else
  pkgs.runCommand "moonbit-${lib.replaceStrings [ "/" ] [ "-" ] module.name}-${module.version}-source"
    {
      nativeBuildInputs = [ pkgs.unzip ];
    }
    ''
      mkdir -p "$out"
      unzip -q ${archive} -d "$out"
      # Registry archives have their manifests at the archive root.
      test -f "$out/moon.mod" || test -f "$out/moon.mod.json"
    ''
