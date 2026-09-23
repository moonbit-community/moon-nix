# moon2nix

Build MoonBit projects with Nix. Toolchains come from **moonbit-overlay**;
this repository owns dependency packaging, project builders, and generated
build graphs.

The standalone **moon2nix** generator provides package discovery, dependency
solving, build planning, and command rendering. Its structured build plan is
rendered directly as a `moon.nix` expression. Nix consumes it as one derivation
per build action, with explicit artifact dependencies. Like cargo2nix,
generation is a separate step: importing a checked-in plan does not run a
resolver or compiler during Nix evaluation.

## Development

The flake currently follows the `fix/modernize-moonbit-tests` branch of
`moonbit-overlay`, with its exact revision recorded in `flake.lock`. This can
return to the overlay's default branch after the SDK-interface refactor lands.
The library itself takes `pkgs` and `toolchain` explicitly.

```bash
nix build .#moon2nix
nix flake check
```

The flake supports `x86_64-linux` and `aarch64-darwin`. Linux builds have been
executed locally; Darwin outputs can be evaluated but require a Darwin builder
for execution.

## Generate and build a plan

From a project containing an app module and its dependency source, export a
build plan for the app's main package:

```bash
toolchain=$(nix build github:moonbit-community/moonbit-overlay/fix/modernize-moonbit-tests#latest \
  --no-link --print-out-paths)
nix run . -- \
  ./app my-org/app/main wasm-gc "$toolchain" \
  ./dependency > moon.nix
```

Arguments are `ROOT MAIN_PACKAGE TARGET TOOLCHAIN [--registry-index INDEX_DIR]
[DEPENDENCY_ROOT ...]`. The root module comes first, followed by dependency
module roots. With `--registry-index`, the generator applies Moon's minimum
version selection to the root manifest and the transitive requirements in the
given registry index. It checks that every selected module has a supplied
source root at the selected version, and writes `resolvedModules` (version,
registry checksum, and source index) into `moon.nix`. The index must be pinned
by the caller; changing it can change the selected graph. The generator does
not yet fetch selected modules automatically. Pin their sources with Nix
fetchers and keep the source list in the same order at build time. Without the
flag, the existing explicit-source workflow remains available.

```nix
let
  moon2nix = inputs.moon2nix.lib.mkMoon2Nix {
    inherit pkgs;
    toolchain = moonbit-overlay.packages.${pkgs.system}.latest;
  };
in moon2nix.buildPlan {
  plan = import ./moon.nix;
  sources = [ ./app ./dependency ];
}
```

The result contains `bin/main.wasm`. Run it with the toolchain's `moonrun`.
Use `native` to generate a native plan; its output is `bin/main.exe` on Linux.
`js` is also accepted by the generator. Keep the toolchain pinned alongside the
plan and regenerate the plan when the toolchain, manifests, source-file list,
imports, or selected target changes.

Plans use `@src0@`, `@src1@`, `@toolchain@`, and `@build@` placeholders rather
than machine-specific paths. Nix maps each produced artifact to its owning
derivation, including transitive `.mi` interfaces needed by `-all-pkgs`.
Unrelated module roots are excluded from an action's source substitutions;
source invalidation within a module is currently at module granularity.

`buildPlan` accepts `name`, `stdenv`, and additional `nativeBuildInputs`. Native
compilation uses the compiler provided by Nix's `stdenv`; the generator does not
probe a compiler on the machine exporting the plan. For example, pass
`stdenv = pkgs.clangStdenv;` to use Clang. Its `passthru` exposes `actions`
(by artifact ID) and `roots` for inspecting the graph.

## Build a bundle

Export a module bundle with `moon2nix bundle ROOT TARGET TOOLCHAIN
[--registry-index INDEX_DIR] [DEPENDENCY_ROOT ...]`. For example, rebuild core:

```bash
nix run . -- bundle "$toolchain/lib/core" wasm-gc "$toolchain" > core.nix
```

Build the exported plan and use it as the standard library for another plan:

```nix
let
  coreBundle = moon2nix.buildPlan {
    name = "moonbit-core";
    plan = import ./core.nix;
    sources = [ "${toolchain}/lib/core" ];
  };
in moon2nix.buildPlan {
  plan = import ./moon.nix;
  sources = [ ./app ./dependency ];
  stdlib = coreBundle;
}
```

Bundle outputs contain the merged `.core`, all package `.mi` interfaces with
relative directories preserved, and separate virtual default implementations.
Building `moonbitlang/core` disables the precompiled standard-library input;
ordinary module bundles still use the standard library. The `stdlib` argument
replaces the standard-library bundle while retaining the configured compiler
and native runtime. Use the same target and pinned toolchain for both plans.

## Existing builders

Initialize the build library with `mkMoon2Nix { pkgs = ...; toolchain = ...; }`,
or without flakes:

```nix
moon2nix = import ./default.nix { inherit pkgs toolchain; };
```

- `buildCachedRegistry`: fetch exact-version dependencies into an offline
  registry.
- `buildMoonbitPackage`, `buildMoonbitInterface`, `linkMoonbitProgram`: compile
  and link individual packages directly with `moonc`.
- `buildMoonbitRuntime`, `makeMoonbitExecutable`, the C/Zig/Objective-C stub
  builders, `translateMoonbitCHeader`, `archiveMoonbitStubs`, and
  `runMoonbitPrebuild`: lower-level build primitives.

The registry builder preserves the previous **exact-version** traversal; it is
not a replacement for moon's general module-version resolver. The generated
plan path currently uses structured commands, while the migrated
fine-grained builders remain available as direct building blocks.

## Current boundaries

This is an initial implementation, without full opam-nix/cargo2nix feature parity.
The generator handles a selected executable package or a module bundle with
`wasm-gc`, `native`, or `js`. Automatic registry source fetching, workspace discovery, test-plan export,
cross compilation, and prebuild export are not implemented. Pass dependency
module roots explicitly. Prebuild declarations are rejected before
planning can execute scripts. Existing direct prebuild builders remain usable
by callers who construct their own graph.

The resolver port from `moonbit-community/moon` retains one selected version
per compatibility group. The build planner gives those versions separate
identities and resolves each import through its declaring module's dependency
edge. Registry `bin-deps` and local workspace overrides are not included in
this CLI's version selection yet.

Native plans encode host-specific linking decisions and must be generated for
the build host. Zig/Objective-C support in the migrated builders is not yet
wired into the generator CLI's native toolchain configuration.

## Validation

`nix flake check` validates the Nix files' formatting.

The Nix builders use the [MIT license](LICENSE). The MoonBit generator sources
use [Apache-2.0](generator/LICENSE).
