{ pkgs, toolchain }:
let
  inherit (pkgs) lib;
  api = import ../../default.nix { inherit pkgs toolchain; };
  manifest = import ../../lib/pure/manifest.nix { inherit lib; };
  resolver = import ../../lib/pure/resolve.nix { inherit lib manifest; };
  registry = {
    "test/lib" = {
      "0.1.0" = {
        src = ./fixtures/lib-old;
      };
      "2.0.0" = {
        src = ./fixtures/lib-new;
      };
    };
    "test/bridge"."1.0.0" = {
      src = ./fixtures/bridge;
      deps."test/lib" = "2.0.0";
    };
  };
  project =
    target:
    api.buildProject {
      src = ./fixtures/app;
      mainPackage = "test/app/main";
      inherit registry target;
    };
  cProject = api.buildProject {
    src = ./fixtures/c-stub;
    mainPackage = "test/cstub/main";
    target = "native";
  };
  archiveRegistry = {
    "test/lib" = {
      "0.1.0" = {
        url = "file://${./fixtures/registry-download/user/test/lib/0.1.0.zip}";
        checksum = "24b6def2e0d26d96c4d7fcd664d124cfd559a5714ae78b6da070a088e698103d";
      };
      "2.0.0" = {
        url = "file://${./fixtures/registry-download/user/test/lib/2.0.0.zip}";
        checksum = "0a9c9b256cfcf33c3a0e1860ba7474924d68b951b62748a9c8345cc2c67e6e59";
      };
    };
    "test/bridge"."1.0.0" = {
      url = "file://${./fixtures/registry-download/user/test/bridge/1.0.0.zip}";
      checksum = "7b2bf1468c7adcd7be5b42521a1026b9fcb1a6915298acd94cbc49a48feaef84";
      deps."test/lib" = "2.0.0";
    };
  };
  archiveProject = api.buildProject {
    src = ./fixtures/app;
    mainPackage = "test/app/main";
    target = "native";
    registry = ./fixtures/registry;
    registryDownloadUrl = "file://${./fixtures/registry-download}";
  };
  workspaceProject =
    target:
    api.buildProject {
      src = ./fixtures/workspace;
      mainPackage = "work/app/main";
      inherit target registry;
      prebuildInputs = _: [ pkgs.python3 ];
    };
  generatedCProject = api.buildProject {
    src = ./fixtures/generated-c;
    mainPackage = "test/generated/main";
    target = "native";
    prebuildInputs = _: [ pkgs.python3 ];
  };
  virtualProject =
    target: entry:
    api.buildProject {
      src = ./fixtures/virtual;
      mainPackage = "test/virtual/main-${entry}";
      inherit target;
    };
  prebuildRules =
    rules:
    (import ../../lib/pure/prebuild.nix {
      inherit pkgs toolchain;
      stdenv = pkgs.stdenv;
      nativeBuildInputs = [ ];
      prebuildInputs = _: [ ];
    })
      {
        fqn = "test/generated/main";
        stem = "invalid-prebuild";
        directory = ./fixtures/generated-c/main;
        module = {
          source = ./fixtures/generated-c;
          raw = { };
        };
        raw.pre-build = rules;
      };
  parsed = api.parseManifest "module" ''
    // punctuation and comments inside strings stay intact
    name = "test/parser"
    import { "test/lib@1.0.0" }
    options(source: "src", "compile-flags": ["-O2",], rule: [{ "name": "https://example.test/a", "command": "echo \"hi\"" },])
  '';
  resolved = api.resolveDependencies {
    root.deps = {
      "test/lib" = "0.1.0";
      "test/bridge" = "1.0.0";
    };
    inherit registry;
  };
  rejected = expression: !(builtins.tryEval (builtins.deepSeq expression true)).success;
  upgraded = resolver.resolve {
    root.deps = {
      a = "1.0.0";
      b = "1.0.0";
    };
    registry = {
      a."1.0.0".deps.c = "0.1.0";
      b."1.0.0".deps.c = "1.1.0";
      c = {
        "0.1.0" = { };
        "1.1.0" = { };
        "1.9.0" = { };
      };
    };
  };
  checks = {
    parser =
      parsed.name == "test/parser"
      && parsed.source == "src"
      && parsed.deps."test/lib" == "1.0.0"
      &&
        parsed.rule == [
          {
            name = "https://example.test/a";
            command = ''echo "hi"'';
          }
        ];
    multipleVersions =
      resolved.selected."test/lib" == [
        "0.1.0"
        "2.0.0"
      ]
      && resolved.modules."test/bridge@1.0.0".edges."test/lib" == "test/lib@2.0.0";
    minimumVersion = upgraded.selected.c == [ "1.1.0" ];
    compatible01 = resolver.satisfies "0.1.0" "1.0.0" && !resolver.satisfies "1.0.0" "2.0.0";
    semver =
      resolver.versionCompare "1.0.0-alpha.2" "1.0.0-alpha.10" < 0
      && resolver.versionCompare "1.0.0-rc.1" "1.0.0" < 0
      && resolver.versionCompare "1.0.0+x" "1.0.0+y" == 0;
    index =
      (resolver.resolve {
        root.deps."test/lib" = "0.1.0";
        registry = ./fixtures/index;
      }).selected."test/lib" == [ "0.1.0" ];
    fetchedSource =
      builtins.length
        (api.buildProject {
          src = ./fixtures/app;
          mainPackage = "test/app/main";
          registry = registry // {
            "test/lib" = registry."test/lib" // {
              "0.1.0" = {
                url = "file://${./fixtures/lib-old.tar.gz}";
                narHash = "sha256-plDHh7RxcPVArDAR/a8lgh0qKraes91QeEKwJq+C1VY=";
              };
            };
          };
        }).passthru.plan.order == 4;
    wrongSource = rejected (
      api.buildProject {
        src = ./fixtures/app;
        mainPackage = "test/app/main";
        inherit registry;
        sources."test/lib@0.1.0" = ./fixtures/lib-new;
      }
    );
    undeclaredImport = rejected (
      api.buildProject {
        src = ./fixtures/app;
        mainPackage = "test/app/main";
        registry = registry // {
          "test/bridge"."1.0.0" = {
            src = ./fixtures/bridge;
          };
        };
      }
    );
    versionCycle =
      (resolver.resolve {
        root.deps.a = "1.0.0";
        registry = {
          a."1.0.0".deps.b = "1.0.0";
          b."1.0.0".deps.a = "1.0.0";
        };
      }).selected == {
        a = [ "1.0.0" ];
        b = [ "1.0.0" ];
      };
    traversal = rejected (
      resolver.resolve {
        root.deps."../outside" = "1.0.0";
        registry = ./fixtures/index;
      }
    );
    workspace =
      builtins.length (workspaceProject "wasm-gc").plan.order == 3
      && !(workspaceProject "wasm-gc").plan.resolution.selected ? "work/shared";
    prebuildChain =
      builtins.length (workspaceProject "wasm-gc").actions.prebuild."work/app@0.1.0|main" == 2;
    prebuildCycle = rejected (prebuildRules [
      {
        input = "b.mbt";
        output = "a.mbt";
        command = "cp $input $output";
      }
      {
        input = "a.mbt";
        output = "b.mbt";
        command = "cp $input $output";
      }
    ]);
    prebuildDuplicate = rejected (prebuildRules [
      {
        output = "a.mbt";
        command = "touch $output";
      }
      {
        output = "a.mbt";
        command = "touch $output";
      }
    ]);
    virtualLink =
      builtins.elem "test/virtual@local|impl" (virtualProject "wasm-gc" "override").plan.linkOrder
      && !builtins.elem "test/virtual@local|api" (virtualProject "wasm-gc" "override").plan.linkOrder;
    missingImplementation = rejected (virtualProject "wasm-gc" "missing");
    conflictingOverrides = rejected (virtualProject "wasm-gc" "conflict");
    sharedConsumer =
      (virtualProject "wasm-gc" "default").actions."test/virtual@local|consumer".drvPath
      == (virtualProject "wasm-gc" "override").actions."test/virtual@local|consumer".drvPath;
    cArchives =
      builtins.length (builtins.attrNames cProject.actions.cStubs) == 3
      && builtins.length cProject.actions.cStubs."test/cstub@local|lib".objects == 2;
    invalidVersion = rejected (resolver.semver "01.0.0");
    missingVersion = rejected (resolver.resolve { root.deps.x = "1.0.0"; });
    invalidSyntax = rejected (api.parseManifest "package" ''import { "x" as }'');
    cycle = rejected (
      api.buildProject {
        src = ./fixtures/cycle;
        mainPackage = "test/cycle/main";
      }
    );
    missingMain = rejected (
      api.buildProject {
        src = ./fixtures/prebuild;
        mainPackage = "test/prebuild/main";
      }
    );
    graph =
      builtins.length (project "wasm-gc").passthru.plan.order == 4
      && (project "wasm-gc").passthru.plan.packages."test/app@0.1.0|main".files == [ "main.mbt" ];
    jsFiles =
      (project "js").passthru.plan.packages."test/app@0.1.0|main".files == [
        "main.js.mbt"
        "main.mbt"
      ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: value: !value) checks);
  evaluation =
    if failures != [ ] then
      throw "pure Nix checks failed: ${lib.concatStringsSep ", " failures}"
    else
      pkgs.writeText "moon2nix-pure-evaluation" (builtins.toJSON checks);
in
{
  inherit
    evaluation
    checks
    archiveRegistry
    archiveProject
    ;
  workspace-prebuild =
    pkgs.runCommand "moon2nix-workspace-prebuild-test" { nativeBuildInputs = [ toolchain ]; }
      ''
        moonrun ${workspaceProject "wasm-gc"}/bin/main.wasm > result
        test "$(cat result)" = 42
        cp result $out
      '';
  generated-c = pkgs.runCommand "moon2nix-generated-c-test" { } ''
    ${generatedCProject}/bin/main > result
    test "$(cat result)" = 42
    cp result $out
  '';
  virtual =
    pkgs.runCommand "moon2nix-virtual-test"
      {
        nativeBuildInputs = [
          toolchain
          pkgs.nodejs
        ];
      }
      ''
        ${lib.concatMapStringsSep "\n"
          (
            target:
            lib.concatMapStringsSep "\n"
              (
                entry:
                let
                  project = virtualProject target entry;
                  expected =
                    if entry == "default" then
                      "11"
                    else if entry == "override" then
                      "12"
                    else if entry == "abort" then
                      "13"
                    else
                      "7";
                  command =
                    if target == "native" then
                      "${project}/bin/main"
                    else if target == "js" then
                      "node ${project}/bin/main.js"
                    else
                      "moonrun ${project}/bin/main.wasm";
                in
                "${command} > result\ntest \"$(cat result)\" = ${expected}"
              )
              [
                "default"
                "override"
                "abstract"
                "abort"
              ]
          )
          [
            "wasm-gc"
            "js"
            "native"
          ]
        }
        cp result $out
      '';
  c-stub = pkgs.runCommand "moon2nix-c-stub-test" { } ''
    ${cProject}/bin/main > result
    test "$(cat result)" = 43
    cp result $out
  '';
  registry-source = pkgs.runCommand "moon2nix-registry-source-test" { } ''
    ${archiveProject}/bin/main > result
    test "$(cat result)" = 3
    cp result $out
  '';
  wasm = pkgs.runCommand "moon2nix-pure-wasm-test" { nativeBuildInputs = [ toolchain ]; } ''
    moonrun ${project "wasm-gc"}/bin/main.wasm > result
    test "$(cat result)" = 3
    cp result $out
  '';
  js = pkgs.runCommand "moon2nix-pure-js-test" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    node ${project "js"}/bin/main.js > result
    test "$(cat result)" = 3
    cp result $out
  '';
  native = pkgs.runCommand "moon2nix-pure-native-test" { } ''
    ${project "native"}/bin/main > result
    test "$(cat result)" = 3
    cp result $out
  '';
}
