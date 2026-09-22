# moon-nix

Build MoonBit projects with Nix. Toolchains come from **moonbit-overlay**;
this repository owns dependency packaging, project builders, and generated
build graphs.

The standalone **moon-nix-plan** generator reuses the parser, package discovery,
package dependency solver, build planner, and command renderer extracted from
[moonbit-community/moon](https://github.com/moonbit-community/moon). Its JSON
output is consumed by Nix as one derivation per build action, with explicit
artifact dependencies. Like cargo2nix, generation is a separate step: importing
a checked-in plan does not run a resolver or compiler during Nix evaluation.

## Development

The flake currently follows the `fix/modernize-moonbit-tests` branch of
`moonbit-overlay`, with its exact revision recorded in `flake.lock`. This can
return to the overlay's default branch after the SDK-interface refactor lands.
The library itself takes `pkgs` and `toolchain` explicitly.

```bash
nix build .#generator
nix flake check
```

The flake supports `x86_64-linux` and `aarch64-darwin`. Linux builds have been
executed locally; Darwin outputs can be evaluated but require a Darwin builder
for execution.

## Generate and build a plan

From this repository, export a build plan for the example's main package:

```bash
toolchain=$(nix build github:moonbit-community/moonbit-overlay/fix/modernize-moonbit-tests#latest \
  --no-link --print-out-paths)
nix run .#generator -- \
  ./examples/hello example/hello/main wasm-gc "$toolchain" \
  ./examples/support > moon-nix-plan.json
```

Arguments are `ROOT MAIN_PACKAGE TARGET TOOLCHAIN [DEPENDENCY_ROOT ...]`.
The root module comes first, followed by already-resolved dependency module
roots. The generator discovers packages and resolves imports across those
modules; it does not download dependencies or perform registry version
selection. Pin external module sources with Nix fetchers, or use the migrated
registry builder described below. Keep the source list in the same order at
build time.

```nix
let
  moonNix = moon-nix.lib.mkMoonNix {
    inherit pkgs;
    toolchain = moonbit-overlay.packages.${pkgs.system}.latest;
  };
in moonNix.buildPlan {
  plan = ./moon-nix-plan.json;
  sources = [ ./examples/hello ./examples/support ];
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

`buildPlan` accepts `name` and additional `nativeBuildInputs`. Its `passthru`
exposes `actions` (by artifact ID) and `roots` for inspecting the graph.

## Existing builders

The original `moonPlatform` implementation and tests have moved here. Initialize
it with `mkMoonNix { pkgs = ...; toolchain = ...; }`, or without flakes:

```nix
moonNix = import ./default.nix { inherit pkgs toolchain; };
```

- `buildMoonPackage`: run `moon build` for a project with explicit `moonMod`
  metadata and a pinned `moonRegistryIndex`.
- `buildCachedRegistry`, `bundleWithRegistry`: create an offline registry and
  build home using the supplied complete toolchain.
- `buildMoonbitPackage`, `buildMoonbitInterface`, `linkMoonbitProgram`: compile
  and link individual packages directly with `moonc`.
- `buildMoonbitRuntime`, `makeMoonbitExecutable`, the C/Zig/Objective-C stub
  builders, `translateMoonbitCHeader`, `archiveMoonbitStubs`, and
  `runMoonbitPrebuild`: lower-level build primitives.

The registry builder preserves the previous **exact-version** traversal; it is
not a replacement for moon's general module-version resolver. The generated
plan path currently uses the extracted structured commands, while the migrated
fine-grained builders remain available as direct building blocks.

## Current boundaries

This is an initial working extraction, not full opam-nix/cargo2nix feature parity.
The generator handles a selected executable package with `wasm-gc`, `native`,
or `js`. Automatic registry resolution, workspace discovery, test-plan export,
cross compilation, and prebuild export are not implemented. Pass dependency
module roots explicitly. Prebuild declarations are rejected before upstream
planning can execute scripts. Existing direct prebuild builders remain usable
by callers who construct their own graph.

Native plans encode host-specific linking decisions and must be generated for
the build host. Zig/Objective-C support in the migrated builders is not yet
wired into the generator CLI's native toolchain configuration.

## Validation and provenance

`nix flake check` covers the generator, deterministic relocation, missing
imports and unsupported/prebuild rejection, generated Wasm and Linux native
plans across two modules, the migrated direct compiler builders, and a registry
project build. The generated examples print `42`.

[generator/UPSTREAM.json](generator/UPSTREAM.json) records the exact moon revision
and extracted packages. The planner core is copied with only trailing-whitespace cleanup; upstream
test files and test-only imports are omitted. The standalone CLI also adapts the
`provision_local_inputs` package-listing logic from moon's `src/main/session.mbt`
so each Nix action gets the required `all_pkgs.json` without creating a cyclic
build graph. [generator.nix](generator.nix) pins the upstream `x` OS library and
uses a small registry snapshot for the generator's other dependencies.

The Nix builders retain the overlay's [MIT license](LICENSE). Extracted MoonBit
sources and the generator use [Apache-2.0](generator/LICENSE).
