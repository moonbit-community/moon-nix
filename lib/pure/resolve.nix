# Moon MVS: minimum available per requirement, maximum reached per compatibility
# group. Majors 0 and 1 share a group; every major >= 2 is separate.
{ lib, manifest }:
let
  fail = message: throw "moon2nix resolve: ${message}";
  semver =
    version:
    let
      match = builtins.match "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-([0-9A-Za-z.-]+))?(\\+([0-9A-Za-z.-]+))?" version;
      prerelease =
        if match == null || builtins.elemAt match 4 == null then
          [ ]
        else
          lib.splitString "." (builtins.elemAt match 4);
      numeric = s: builtins.match "[0-9]+" s != null;
      validIdentifier = s: s != "" && !(numeric s && builtins.stringLength s > 1 && lib.hasPrefix "0" s);
      metadata =
        if match == null || builtins.elemAt match 6 == null then
          [ ]
        else
          lib.splitString "." (builtins.elemAt match 6);
    in
    if match == null || !lib.all validIdentifier prerelease || lib.any (s: s == "") metadata then
      fail "invalid semver ${version}"
    else
      {
        core = map builtins.fromJSON (lib.take 3 match);
        pre = prerelease;
      };
  compareList =
    cmp: a: b:
    if a == [ ] then
      (if b == [ ] then 0 else -1)
    else if b == [ ] then
      1
    else
      let
        c = cmp (builtins.head a) (builtins.head b);
      in
      if c == 0 then compareList cmp (builtins.tail a) (builtins.tail b) else c;
  compare =
    a: b:
    if a < b then
      -1
    else if a > b then
      1
    else
      0;
  comparePre =
    a: b:
    let
      an = builtins.match "[0-9]+" a != null;
      bn = builtins.match "[0-9]+" b != null;
    in
    if an && bn then
      compare (builtins.fromJSON a) (builtins.fromJSON b)
    else if an then
      -1
    else if bn then
      1
    else
      compare a b;
  versionCompare =
    a: b:
    let
      av = semver a;
      bv = semver b;
      c = compareList compare av.core bv.core;
    in
    if c != 0 then
      c
    else if av.pre == [ ] then
      (if bv.pre == [ ] then 0 else 1)
    else if bv.pre == [ ] then
      -1
    else
      compareList comparePre av.pre bv.pre;
  group =
    version:
    let
      major = builtins.head (semver version).core;
    in
    toString (if major < 2 then 0 else major);
  satisfies =
    required: candidate: group required == group candidate && versionCompare candidate required >= 0;
  deps =
    raw:
    let
      specs = raw.deps or { };
    in
    if !builtins.isAttrs specs then
      fail "deps must be an object"
    else
      lib.mapAttrsToList (name: spec: {
        inherit name;
        version =
          if builtins.isString spec then
            spec
          else if builtins.isAttrs spec && spec ? version && !(spec ? path) then
            spec.version
          else
            fail "${name}: expected registry version";
      }) specs;
  registryReader =
    registry: name:
    let
      file = if builtins.isAttrs registry then null else registry + "/user/${name}.index";
      records =
        if file != null && builtins.pathExists file then
          map (line: manifest.normalize (builtins.fromJSON line)) (
            builtins.filter (line: builtins.match "[[:space:]]*" line == null) (
              lib.splitString "\n" (builtins.readFile file)
            )
          )
        else
          [ ];
    in
    if builtins.match "[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*" name == null then
      fail "invalid module name ${name}"
    else if builtins.isAttrs registry then
      registry.${name} or (fail "module ${name} missing from registry")
    else if records == [ ] then
      fail "module ${name} missing from registry"
    else
      builtins.listToAttrs (
        map (
          record:
          if (record.name or null) != name || !(record ? version) then
            fail "invalid record in ${toString file}"
          else
            {
              name = record.version;
              value = record;
            }
        ) records
      );
  resolve =
    {
      root,
      registry ? { },
      localModules ? { },
    }:
    let
      readRegistry = registryReader registry;
      walk =
        queue: state:
        if queue == [ ] then
          state
        else
          let
            requirement = builtins.head queue;
            available = readRegistry requirement.name;
            candidates = builtins.sort (a: b: versionCompare a b < 0) (
              builtins.filter (satisfies requirement.version) (builtins.attrNames available)
            );
            version =
              if candidates == [ ] then
                fail "no version of ${requirement.name} satisfies ${requirement.version}"
              else
                builtins.head candidates;
            key = "${requirement.name}@${version}";
            entry = available.${version};
            seen = state.visited ? ${key};
            next = {
              visited = state.visited // {
                ${key} = true;
              };
              gathered = state.gathered // {
                ${requirement.name} = lib.unique ((state.gathered.${requirement.name} or [ ]) ++ [ version ]);
              };
            };
          in
          if localModules ? ${requirement.name} then
            walk (builtins.tail queue) state
          else
            walk (builtins.tail queue ++ lib.optionals (!seen) (deps entry)) next;
      gathered =
        (walk (deps root ++ lib.concatMap (m: deps m.raw) (builtins.attrValues localModules)) {
          visited = { };
          gathered = { };
        }).gathered;
      selected = lib.mapAttrs (
        _: versions:
        builtins.attrValues (
          lib.foldl' (
            sets: version:
            let
              g = group version;
              previous = sets.${g} or version;
            in
            sets // { ${g} = if versionCompare version previous > 0 then version else previous; }
          ) { } versions
        )
      ) gathered;
      select =
        name: required:
        let
          matches = builtins.filter (satisfies required) (selected.${name} or [ ]);
        in
        if matches == [ ] then
          fail "no settled version of ${name} satisfies ${required}"
        else
          builtins.head matches;
      edges =
        raw:
        builtins.listToAttrs (
          map (d: {
            name = d.name;
            value =
              if localModules ? ${d.name} then
                localModules.${d.name}.key
              else
                "${d.name}@${select d.name d.version}";
          }) (deps raw)
        );
      modules = builtins.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            name: versions:
            map (version: {
              name = "${name}@${version}";
              value = {
                inherit name version;
                entry = (readRegistry name).${version};
                edges = edges (readRegistry name).${version};
              };
            }) versions
          ) selected
        )
      );
    in
    {
      inherit selected modules;
      rootEdges = edges root;
      localEdges = lib.mapAttrs (_: m: edges m.raw) localModules;
    };
in
{
  inherit
    semver
    versionCompare
    group
    satisfies
    deps
    registryReader
    resolve
    ;
}
