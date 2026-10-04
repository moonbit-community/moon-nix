{
  pkgs,
  toolchain,
  manifest,
  resolver,
  builders,
}:
let
  inherit (pkgs) lib;
  fail = message: throw "moon-nix project: ${message}";
  backends = [
    "wasm-gc"
    "wasm"
    "js"
    "native"
    "llvm"
  ];
  safeRelative =
    value:
    builtins.isString value
    && !lib.hasPrefix "/" value
    && lib.all (part: part != ".." && part != ".") (lib.splitString "/" value);
  assertRelative =
    value: if safeRelative value then value else fail "unsafe relative path ${toString value}";
  supported =
    target: expr:
    let
      text = builtins.replaceStrings [ " " "\t" "\n" ] [ "" "" "" ] expr;
      n = builtins.stringLength text;
      walk =
        i: first: selected:
        if i == n then
          selected
        else
          let
            c = builtins.substring i 1 text;
            op =
              if c == "+" || c == "-" then
                c
              else if first then
                "+"
              else
                fail "invalid supported-targets ${expr}";
            start = i + (if c == "+" || c == "-" then 1 else 0);
            candidates = builtins.filter (
              token: lib.hasPrefix token (builtins.substring start (n - start) text)
            ) (backends ++ [ "all" ]);
            token =
              if candidates == [ ] then fail "invalid supported-targets ${expr}" else builtins.head candidates;
            additions = if token == "all" then lib.remove "llvm" backends else [ token ];
          in
          walk (start + builtins.stringLength token) false (
            if op == "+" then
              lib.unique (selected ++ additions)
            else
              builtins.filter (x: !builtins.elem x additions) selected
          );
    in
    if builtins.isList expr then
      lib.any (supported target) expr
    else if !builtins.isString expr || text == "" then
      fail "invalid supported-targets"
    else
      builtins.elem target (walk 0 true [ ]);
  condition =
    target: expr:
    if builtins.isString expr then
      if
        !builtins.elem expr (
          backends
          ++ [
            "debug"
            "release"
          ]
        )
      then
        fail "unknown target condition ${expr}"
      else
        expr == target || expr == "release"
    else if builtins.isList expr && expr != [ ] then
      let
        head = builtins.head expr;
        rest = builtins.tail expr;
      in
      if head == "and" then
        lib.all (condition target) rest
      else if head == "or" then
        lib.any (condition target) rest
      else if head == "not" then
        !lib.any (condition target) rest
      else
        lib.any (condition target) expr
    else
      fail "invalid target condition";
  checkUnsupported =
    context: raw: keys:
    let
      found = builtins.filter (
        key:
        raw ? ${key}
        && !builtins.elem raw.${key} [
          null
          false
          [ ]
          { }
        ]
      ) keys;
    in
    if found == [ ] then
      raw
    else
      fail "${context}: unsupported features: ${lib.concatStringsSep ", " found}";

in
{
  src,
  mainPackage,
  registry ? { },
  sources ? { },
  target ? "wasm-gc",
  name ? "moonbit-project",
  registryDownloadUrl ? "https://download.mooncakes.io",
  sourceFetcher ? (import ./fetchSource.nix { inherit pkgs; }) {
    downloadBase = registryDownloadUrl;
  },
  nativePackageInputs ? package: [ ],
  localSources ? [ ],
  prebuildInputs ? package: [ ],
  runDependencyPrebuilds ? false,
  stdenv ? pkgs.stdenv,
  nativeBuildInputs ? [ ],
  actionOverrides ? action: { },
}:
let
  readModule =
    root:
    let
      raw = checkUnsupported (toString root) (manifest.read "module" root) [
        "bin-deps"
        "moonbit-unstable-prebuild"
        "--moonbit-unstable-prebuild"
      ];
    in
    if !(raw ? name) || !builtins.isString raw.name || raw.name == "" then
      fail "module needs a name"
    else if raw ? supported-targets && !supported target raw.supported-targets then
      fail "module ${raw.name} does not support ${target}"
    else if raw.name == "moonbitlang/core" then
      fail "building core requires a module bundle, which buildProject does not support yet"
    else
      builtins.deepSeq (if raw ? version then resolver.semver raw.version else null) raw;
  workspace =
    if builtins.pathExists (src + "/moon.work") then
      manifest.parseDSL "workspace" (builtins.readFile (src + "/moon.work"))
    else
      null;
  workspaceSources =
    if workspace == null then
      [ src ]
    else
      map (member: src + "/${if member == "." then "" else assertRelative member}") (
        workspace.members or [ ]
      );
  localList = map (
    source:
    let
      raw = readModule source;
    in
    {
      inherit source raw;
      name = raw.name;
      key = "${raw.name}@${raw.version or "local"}";
    }
  ) (lib.unique (workspaceSources ++ localSources));
  localNames = map (m: m.name) localList;
  locals =
    if builtins.length (lib.unique localNames) != builtins.length localNames then
      fail "duplicate workspace module name"
    else
      builtins.listToAttrs (
        map (m: {
          name = m.name;
          value = m;
        }) localList
      );
  rootCandidates = builtins.sort (a: b: builtins.stringLength a.name > builtins.stringLength b.name) (
    builtins.filter (m: mainPackage == m.name || lib.hasPrefix "${m.name}/" mainPackage) localList
  );
  rootModule =
    if rootCandidates == [ ] then
      fail "main package does not belong to a workspace member"
    else
      builtins.head rootCandidates;
  rootManifest = rootModule.raw;
  rootKey = rootModule.key;
  resolution = resolver.resolve {
    root = rootManifest;
    inherit registry;
    localModules = locals;
  };
  moduleMap =
    lib.mapAttrs (
      key: m:
      let
        source = sources.${key} or (sourceFetcher m);
        raw = readModule source;
      in
      if raw.name != m.name || (raw.version or null) != m.version then
        fail "source identity does not match ${key}"
      else
        m
        // {
          inherit source raw;
          local = false;
        }
    ) resolution.modules
    // builtins.listToAttrs (
      map (m: {
        name = m.key;
        value = m // {
          local = true;
          edges = resolution.localEdges.${m.name};
        };
      }) localList
    );
  scanRoot =
    m:
    let
      sub = assertRelative (m.raw.source or "");
    in
    m.source + lib.optionalString (sub != "") "/${sub}";
  locate =
    importer: path:
    let
      m = moduleMap.${importer};
      candidates = builtins.filter (
        moduleName: path == moduleName || lib.hasPrefix "${moduleName}/" path
      ) ([ m.name ] ++ builtins.attrNames m.edges);
      sorted = builtins.sort (a: b: builtins.stringLength a > builtins.stringLength b) candidates;
      owner =
        if sorted == [ ] then fail "${importer}: undeclared import ${path}" else builtins.head sorted;
      moduleKey = if owner == m.name then importer else m.edges.${owner};
      rel = assertRelative (if path == owner then "" else lib.removePrefix "${owner}/" path);
    in
    {
      key = "${moduleKey}|${rel}";
      inherit moduleKey rel;
      fqn =
        (if moduleMap.${moduleKey}.local then owner else moduleKey)
        + lib.optionalString (rel != "") "/${rel}";
    };
  importSpec =
    x:
    let
      path = if builtins.isString x then x else x.path or (fail "import needs a path");
      alias =
        if builtins.isAttrs x then x.alias or (builtins.baseNameOf path) else builtins.baseNameOf path;
    in
    if
      !builtins.isString path
      || !safeRelative path
      || builtins.match "[a-zA-Z_][a-zA-Z_0-9]*" alias == null
    then
      fail "invalid import"
    else if builtins.isAttrs x && (x.sub-package or false) then
      fail "sub-package imports are not supported yet"
    else
      { inherit path alias; };
  discover =
    node:
    let
      m = moduleMap.${node.moduleKey};
      directory = scanRoot m + lib.optionalString (node.rel != "") "/${node.rel}";
      raw = checkUnsupported node.fqn (manifest.read "package" directory) [
        "sub-package"
        "import-moonbit-h"
        "link"
      ];
      imports = map importSpec ((raw.import or [ ]) ++ (raw."for-${target}" or [ ]));
      aliases = map (i: i.alias) imports;
      entries = builtins.readDir directory;
      selectedSource =
        file:
        let
          parts = lib.splitString "." file;
          suffix =
            if builtins.length parts >= 3 then builtins.elemAt parts (builtins.length parts - 2) else "";
        in
        lib.hasSuffix ".mbt" file
        && !lib.hasSuffix "_test.mbt" file
        && !lib.hasSuffix "_wbtest.mbt" file
        && (
          if (raw.targets or { }) ? ${file} then
            condition target raw.targets.${file}
          else
            !builtins.elem suffix backends || suffix == target
        );
      stem = "pkg-${builtins.substring 0 20 (builtins.hashString "sha256" node.key)}";
      prebuild =
        if m.local || runDependencyPrebuilds then
          (import ./prebuild.nix {
            inherit
              pkgs
              toolchain
              stdenv
              nativeBuildInputs
              prebuildInputs
              ;
          })
            (
              node
              // {
                inherit raw directory stem;
                module = m;
              }
            )
        else
          {
            derivations = [ ];
            generated = [ ];
          };
      generatedSources = builtins.filter (g: selectedSource g.file) prebuild.generated;
      generatedFiles = map (g: g.file) prebuild.generated;
      files = builtins.filter (
        file: entries.${file} == "regular" && selectedSource file && !builtins.elem file generatedFiles
      ) (builtins.attrNames entries);
      declaredStubs = raw.native-stub or [ ];
      stubs =
        if target != "native" then
          [ ]
        else if !builtins.isList declaredStubs then
          fail "${node.fqn}: native-stub must be a list"
        else
          map (
            file:
            if !builtins.isString file || !safeRelative file || file == "" then
              fail "${node.fqn}: invalid stub path"
            else if !builtins.elem file generatedFiles && !builtins.pathExists (directory + "/${file}") then
              fail "${node.fqn}: missing C stub ${file}"
            else
              file
          ) (lib.unique declaredStubs);
      isVirtual = raw ? virtual;
      hasDefault =
        if !isVirtual then
          false
        else if builtins.isBool raw.virtual then
          raw.virtual
        else
          raw.virtual.has-default or false;
      mbtiName =
        if builtins.pathExists (directory + "/pkg.mbti") || builtins.elem "pkg.mbti" generatedFiles then
          "pkg.mbti"
        else
          builtins.baseNameOf node.fqn + ".mbti";
      mbti =
        if !isVirtual then
          null
        else
          let
            generated = builtins.filter (g: g.file == mbtiName) prebuild.generated;
          in
          if generated != [ ] then
            (builtins.head generated).path
          else if builtins.pathExists (directory + "/${mbtiName}") then
            directory + "/${mbtiName}"
          else
            fail "${node.fqn}: missing virtual interface ${mbtiName}";
      implements =
        if !(raw ? implement) then
          null
        else if raw.implement == "moonbitlang/core/abort" then
          {
            key = "stdlib|abort";
            fqn = raw.implement;
            std = true;
          }
        else
          (locate node.moduleKey raw.implement) // { std = false; };
      overrideNodes = map (path: locate node.moduleKey path) (raw.overrides or [ ]);
      resolvedImports = map (
        i:
        i
        // (
          if lib.hasPrefix "moonbitlang/core/" i.path then
            { std = true; }
          else
            {
              std = false;
              node = locate node.moduleKey i.path;
            }
        )
      ) imports;
    in
    if builtins.length (lib.unique aliases) != builtins.length aliases then
      fail "${node.fqn}: duplicate import alias"
    else if raw ? supported-targets && !supported target raw.supported-targets then
      fail "${node.fqn} does not support ${target}"
    else if raw ? bin-target && raw.bin-target != target then
      fail "${node.fqn}: bin-target disagrees with target"
    else
      node
      // {
        inherit
          raw
          files
          directory
          stubs
          prebuild
          generatedSources
          isVirtual
          hasDefault
          mbti
          implements
          overrideNodes
          ;
        imports = resolvedImports;
        deps = map (i: i.node) (builtins.filter (i: !i.std) resolvedImports);
        module = m;
        inherit stem;
      };
  main = locate rootKey mainPackage;
  # Discovery also follows implementation declarations and root overrides.
  discoverQueue =
    queue: nodes:
    if queue == [ ] then
      nodes
    else
      let
        node = builtins.head queue;
        p = discover node;
      in
      if nodes ? ${node.key} then
        discoverQueue (builtins.tail queue) nodes
      else
        discoverQueue (
          builtins.tail queue
          ++ p.deps
          ++ p.overrideNodes
          ++ lib.optional (p.implements != null && !p.implements.std) p.implements
        ) (nodes // { ${node.key} = p; });
  nodes = discoverQueue [ main ] { };
  mainNode = nodes.${main.key};
  selectedImplementations = map (
    node:
    let
      implementation = nodes.${node.key};
      virtual = implementation.implements;
    in
    if virtual == null then
      fail "${implementation.fqn}: override is not an implementation"
    else if !virtual.std && !nodes.${virtual.key}.isVirtual then
      fail "${virtual.fqn}: implement target is not virtual"
    else
      {
        name = virtual.key;
        value = node.key;
      }
  ) mainNode.overrideNodes;
  overrides =
    if
      builtins.length (lib.unique (map (x: x.name) selectedImplementations))
      != builtins.length selectedImplementations
    then
      fail "multiple overrides of the same virtual package"
    else
      builtins.listToAttrs selectedImplementations;
  compileDeps = p: p.deps ++ lib.optional (p.implements != null && !p.implements.std) p.implements;
  visit =
    key: stack: seen:
    if builtins.elem key stack then
      fail "package dependency cycle: ${lib.concatStringsSep " -> " (stack ++ [ key ])}"
    else if builtins.elem key seen then
      seen
    else
      let
        p = nodes.${key};
        checked =
          if p.implements != null && !p.implements.std && !nodes.${p.implements.key}.isVirtual then
            fail "${p.fqn}: implement target is not virtual"
          else if lib.any (d: nodes.${d.key}.implements != null) p.deps then
            fail "${p.fqn}: import the virtual interface, not its implementation"
          else
            true;
      in
      builtins.seq checked (lib.foldl' (acc: d: visit d.key (stack ++ [ key ]) acc) seen (compileDeps p))
      ++ [ key ];
  compileOrder = lib.foldl' (seen: key: visit key [ ] seen) [ ] (builtins.attrNames nodes);
  choose =
    key:
    let
      p = nodes.${key};
    in
    if !p.isVirtual then
      key
    else if overrides ? ${key} then
      overrides.${key}
    else if p.hasDefault then
      key
    else
      fail "${p.fqn}: no implementation selected and no default";
  linkVisit =
    requested: stack: seen:
    let
      key = choose requested;
      p = nodes.${key};
    in
    if builtins.elem key stack then
      fail "implementation link dependency cycle"
    else if builtins.elem key seen then
      seen
    else
      (lib.foldl' (acc: d: linkVisit d.key (stack ++ [ key ]) acc) seen p.deps) ++ [ key ];
  linkOrder = linkVisit main.key [ ] (
    if overrides ? "stdlib|abort" then linkVisit overrides."stdlib|abort" [ ] [ ] else [ ]
  );
  graph = {
    inherit nodes;
    order = compileOrder;
  };
  closures = lib.mapAttrs (
    _: p: lib.unique (lib.concatMap (d: closures.${d.key} ++ [ d.key ]) (compileDeps p))
  ) nodes;
  token = key: "@dep-${graph.nodes.${key}.stem}@";
  interface = key: "${token key}/${graph.nodes.${key}.stem}.mi";
  core = key: "${token key}/${graph.nodes.${key}.stem}.core";
  bundle = "@toolchain@/lib/core/_build/${target}/release/bundle";
  diagnostics =
    flag: key: p:
    let
      value = (p.module.raw.${key} or "") + (p.raw.${key} or "");
    in
    lib.optionals (value != "") [
      flag
      value
    ];
  compileActions = lib.mapAttrs (
    key: p:
    let
      transitive = closures.${key} ++ lib.optional p.isVirtual key;
      source = builtins.path {
        path = p.directory;
        name = p.stem + "-source";
        filter =
          path: type:
          type == "directory" && toString path == toString p.directory
          || type == "regular" && builtins.elem (builtins.baseNameOf path) p.files;
      };
      action = {
        id = p.stem;
        inputs =
          map (f: "@src0@/${f}") p.files ++ map (g: g.path) p.prebuild.generated ++ map interface transitive;
        outputs = [ "@build@/${p.stem}.core" ] ++ lib.optional (!p.isVirtual) "@build@/${p.stem}.mi";
        command = {
          kind = "exec";
          argv = [
            "moonc"
            "build-package"
          ]
          ++ map (f: "@src0@/${f}") p.files
          ++ map (g: g.path) p.generatedSources
          ++ [
            "-o"
            "@build@/${p.stem}.core"
            "-pkg"
            p.fqn
          ]
          ++ lib.optional (p.raw.is-main or false) "-is-main"
          ++ lib.optional p.isVirtual "-no-mi"
          ++ lib.optionals (p.isVirtual || p.implements != null) [
            "-check-mi"
            (
              if p.isVirtual then
                interface key
              else if p.implements.std then
                "${bundle}/abort/abort.mi"
              else
                interface p.implements.key
            )
          ]
          ++ lib.optional (p.implements != null) "-impl-virtual"
          ++ [
            "-std-path"
            bundle
            "-i"
            "${bundle}/prelude/prelude.mi:prelude"
          ]
          ++ lib.concatMap (i: [
            "-i"
            (
              if i.std then
                "${bundle}/${lib.removePrefix "moonbitlang/core/" i.path}/${builtins.baseNameOf i.path}.mi:${i.alias}"
              else
                "${interface i.node.key}:${i.alias}"
            )
          ]) p.imports
          ++ [
            "-pkg-sources"
            "${p.fqn}:@src0@"
            "-target"
            target
            "-all-pkgs"
            "@build@/all_pkgs.json"
          ]
          ++ diagnostics "-w" "warnings" p
          ++ diagnostics "-alert" "alert-list" p
          ++ (p.module.raw.compile-flags or [ ]);
        };
      };
    in
    builders.buildAction {
      inherit
        action
        target
        stdenv
        nativeBuildInputs
        actionOverrides
        ;
      sources = [ source ];
      dependencies = builtins.listToAttrs (
        map (d: {
          name = token d;
          value = toString interfaces.${d};
        }) transitive
      );
      packages = map (d: {
        root =
          if graph.nodes.${d}.module.local then graph.nodes.${d}.module.name else graph.nodes.${d}.moduleKey;
        rel = graph.nodes.${d}.rel;
        artifact = interface d;
      }) transitive;
    }
  ) (lib.filterAttrs (_: p: !p.isVirtual || p.hasDefault) graph.nodes);
  interfaceActions = lib.mapAttrs (
    key: p:
    let
      transitive = closures.${key};
      generated = lib.any (g: g.path == p.mbti) p.prebuild.generated;
      source = builtins.path {
        path = p.directory;
        name = p.stem + "-interface-source";
        filter =
          path: type:
          type == "directory" && toString path == toString p.directory
          || type == "regular" && builtins.baseNameOf path == builtins.baseNameOf p.mbti;
      };
      contract = if generated then p.mbti else "@src0@/${builtins.baseNameOf p.mbti}";
      contractRoot = if generated then builtins.dirOf p.mbti else "@src0@";
    in
    builders.buildAction {
      inherit
        target
        stdenv
        nativeBuildInputs
        actionOverrides
        ;
      sources = lib.optional (!generated) source;
      packages = map (d: {
        root = if nodes.${d}.module.local then nodes.${d}.module.name else nodes.${d}.moduleKey;
        rel = nodes.${d}.rel;
        artifact = interface d;
      }) transitive;
      dependencies = builtins.listToAttrs (
        map (d: {
          name = token d;
          value = toString interfaces.${d};
        }) transitive
      );
      action = {
        id = "${p.stem}-interface";
        inputs = [ contract ] ++ map interface transitive;
        outputs = [ "@build@/${p.stem}.mi" ];
        command = {
          kind = "exec";
          argv = [
            "moonc"
            "build-interface"
            contract
            "-o"
            "@build@/${p.stem}.mi"
            "-pkg"
            p.fqn
            "-pkg-sources"
            "${p.fqn}:${contractRoot}"
            "-virtual"
            "-std-path"
            bundle
          ]
          ++ lib.concatMap (i: [
            "-i"
            (
              if i.std then
                "${bundle}/${lib.removePrefix "moonbitlang/core/" i.path}/${builtins.baseNameOf i.path}.mi:${i.alias}"
              else
                "${interface i.node.key}:${i.alias}"
            )
          ]) p.imports;
        };
      };
    }
  ) (lib.filterAttrs (_: p: p.isVirtual) nodes);
  interfaces = lib.mapAttrs (
    key: p: if p.isVirtual then interfaceActions.${key} else compileActions.${key}
  ) nodes;
  outputStem = mainNode.raw.bin-name or "main";
  extension =
    if target == "native" then
      "c"
    else if target == "js" then
      "js"
    else
      "wasm";
  linkAction = {
    id = "link-${name}";
    inputs = map core linkOrder;
    outputs = [ "@build@/${outputStem}.${extension}" ];
    command = {
      kind = "exec";
      argv = [
        "moonc"
        "link-core"
      ]
      ++ lib.optional (!(overrides ? "stdlib|abort")) "${bundle}/abort/abort.core"
      ++ [ "${bundle}/core.core" ]
      ++ map core linkOrder
      ++ [
        "-main"
        mainPackage
        "-o"
        "@build@/${outputStem}.${extension}"
        "-target"
        target
      ]
      ++ (rootManifest.link-flags or [ ]);
    };
  };
  linked = builders.buildAction {
    action = linkAction;
    sources = [ ];
    packages = [ ];
    dependencies = builtins.listToAttrs (
      map (d: {
        name = token d;
        value = toString compileActions.${d};
      }) linkOrder
    );
    inherit
      target
      stdenv
      nativeBuildInputs
      actionOverrides
      ;
  };
  runtime = (import ../buildMoonbitRuntime.nix { inherit stdenv; }) { inherit toolchain; };
  cStubPackages = lib.filterAttrs (key: p: p.stubs != [ ] && builtins.elem key linkOrder) graph.nodes;
  # Keep C files and headers together so quoted includes work, without coupling
  # C compilation to MoonBit source changes. Nested header directories are kept.
  cStubActions = lib.mapAttrs (
    _: p:
    let
      originalSource = builtins.path {
        path = p.directory;
        name = p.stem + "-c-source";
        filter =
          path: type:
          if type == "directory" then
            !builtins.elem (builtins.baseNameOf path) [
              ".git"
              "_build"
              ".mooncakes"
              "node_modules"
            ]
          else
            type == "regular"
            && (
              lib.hasSuffix ".h" path
              || builtins.elem (lib.removePrefix (toString p.directory + "/") (toString path)) p.stubs
            );
      };
      generated = builtins.filter (
        g: lib.hasSuffix ".h" g.file || builtins.elem g.file p.stubs
      ) p.prebuild.generated;
      source =
        if generated == [ ] then
          originalSource
        else
          pkgs.runCommand "${p.stem}-generated-c-source" { } ''
            mkdir -p "$out"
            cp -r ${originalSource}/. "$out/"
            chmod -R u+w "$out"
            ${lib.concatMapStringsSep "\n" (g: ''
              mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf g.file)}
              cp ${lib.escapeShellArg g.path} "$out"/${lib.escapeShellArg g.file}
            '') generated}
          '';
      objects = lib.imap0 (
        i: file:
        let
          stem = "${p.stem}-stub-${toString i}";
        in
        {
          name = "${stem}.o";
          drv =
            (import ../buildMoonbitCStub.nix {
              inherit lib stdenv;
              inherit (pkgs) pkg-config;
            })
              {
                pname = stem;
                stub = "${source}/${file}";
                includeDirs = [ source ];
                buildInputs = nativePackageInputs p;
                inherit toolchain nativeBuildInputs;
              };
        }
      ) p.stubs;
      archiveName = "lib${p.stem}";
      archive = (import ../archiveMoonbitStubs.nix { inherit lib stdenv; }) {
        pname = archiveName;
        objs = objects;
      };
    in
    {
      inherit objects archive;
      name = "${archiveName}.a";
    }
  ) cStubPackages;
  stubArchives = map (key: {
    drv = cStubActions.${key}.archive;
    inherit (cStubActions.${key}) name;
  }) (builtins.filter (key: cStubActions ? ${key}) (lib.reverseList linkOrder));
  executable =
    (import ../makeMoonbitExecutable.nix {
      inherit lib stdenv;
      inherit (pkgs) pkg-config;
    })
      {
        pname = outputStem;
        programC = linked;
        inherit runtime toolchain stubArchives;
        buildInputs = lib.unique (lib.concatMap (key: nativePackageInputs graph.nodes.${key}) linkOrder);
        inherit nativeBuildInputs;
      };
  finalArtifact =
    if target == "native" then
      "${executable}/${outputStem}"
    else
      "${linked}/${outputStem}.${extension}";
  plan = {
    inherit resolution linkOrder overrides;
    packages = graph.nodes;
    order = graph.order;
  };
in
if
  !builtins.elem target [
    "wasm-gc"
    "js"
    "native"
  ]
then
  fail "unsupported backend ${target}"
else if !(mainNode.raw.is-main or false) then
  fail "${mainPackage} must declare is-main"
else if builtins.match "[a-zA-Z0-9_][a-zA-Z0-9_.-]*" outputStem == null then
  fail "unsafe bin-name"
else
  builders.finishBuild {
    inherit name;
    kind = "program";
    roots = [ { artifact = finalArtifact; } ];
    actions =
      compileActions
      // {
        link = linked;
        interfaces = interfaceActions;
        prebuild = lib.mapAttrs (_: p: p.prebuild.derivations) graph.nodes;
      }
      // lib.optionalAttrs (target == "native") {
        inherit runtime executable;
        cStubs = cStubActions;
      };
    resolvedModules = resolution.modules;
    passthru = { inherit plan; };
  }
