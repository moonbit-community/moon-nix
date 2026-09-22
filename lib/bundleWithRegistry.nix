# Assemble a home for an offline project build without rebuilding the SDK.
{
  symlinkJoin,
  makeWrapper,
  toolchain,
}:
{ cachedRegistry }:
symlinkJoin {
  name = "moon2nix-home";
  paths = [
    toolchain
    cachedRegistry
  ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/moon --set-default MOON_HOME $out
  '';
}
