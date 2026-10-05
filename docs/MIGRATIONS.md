# Migrating Apollo iOS versions one module at a time

In a large modular app, moving Apollo iOS from one version to another (say 1.15 to 2.4) is hard to do
in one change. The generated code and the runtime API change for every feature at once. rules_apollo
lets one app build against two Apollo iOS versions, called **runtimes**, at the same time. Each module
picks its runtime, and migrating a module is a one-line change plus whatever API changes the new
version needs in that module.

[`examples/rick_and_morty_migration`](../examples/rick_and_morty_migration) is a working app with
Characters and Locations on 1.15.2 and Episodes on 2.4.0.

## How it works

Swift module aliasing ([SE-0339](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0339-module-aliasing-for-disambiguation.md))
lets source that says `import ApolloAPI` load a module that is really named `ApolloAPI_v2`. rules_apollo
builds the second runtime's Apollo iOS under suffixed module names, and compiles every target on that
runtime with those aliases. Only Apollo iOS is aliased. Every other module that exists on both runtimes
is referenced by its real name, so using a `_v2` variant is always explicit in code:

| | `current` runtime (1.15.2) | `next` runtime (2.4.0, `module_suffix = "_v2"`) |
|---|---|---|
| Apollo iOS libraries | `ApolloAPI`, `Apollo`, `ApolloTestSupport` | `ApolloAPI_v2`, `Apollo_v2`, `ApolloTestSupport_v2` |
| Schema types | `RickAndMortyAPI` | `RickAndMortyAPI_v2` |
| Generated operations | `CharactersGraphQL` | `CharactersGraphQL_v2` |
| Your code | `import ApolloAPI`, `import Networking` | `import ApolloAPI` (aliased), `import Networking_v2` (explicit) |

Swift symbols are mangled with their module name, so both runtimes link into one binary. Nothing in
Apollo iOS is forked or renamed. A schema variant is generated with its real name as namespace
(`RickAndMortyAPI_v2.Objects.Episode`).

Each runtime-aware target has a **home runtime** (`runtime = ...`; by default the runtime without a
suffix). It keeps its plain name there. Variants on other runtimes are suffixed, and only built when
something uses them. A feature's own GraphQL module lives on the feature's runtime, so it never needs a
suffix. Every variant is also reachable as `<name>.<runtime>` (e.g. `//graphql:RickAndMortyAPI.next`),
which is how the macros find the right one.

Why not alias every module, so code never mentions `_v2`? Xcode's jump to definition fails for generated
modules reached through an alias ("Couldn't Generate Swift Representation: Could not load module"), even
though the build and the index are correct. Aliasing only Apollo iOS avoids it: jumping to Apollo iOS
types works through the alias.

## Setup

```starlark
# MODULE.bazel
apollo = use_extension("@rules_apollo//apollo:extensions.bzl", "apollo")
apollo.runtime(name = "current", version = "1.15.2")
apollo.runtime(name = "next", version = "2.4.0", module_suffix = "_v2")
```

For each runtime, rules_apollo downloads the CLI and builds Apollo iOS from the upstream release. You
don't write BUILD files for Apollo iOS.

**Generated code:** `apollo_swift_schema`, `apollo_swift_operations` and `apollo_swift_test_mocks`
create one variant per runtime (`<name>` on the home runtime, `<name>_v2` elsewhere, each with its
`_apollo` codegen target).
Bazel only builds the variants something depends on. Each schema variant is generated from every
`.graphql` file, so any feature can move to either runtime without re-partitioning.

**Your code:** use `apollo_swift_library` and say which runtime it's on:

```starlark
apollo_swift_library(
    name = "EpisodesFeature",
    srcs = glob(["Sources/*.swift"]),
    runtime = "next",                       # migrating = changing this line
    runtime_deps = ["//Networking"],        # the "next" variant: `import Networking_v2`
    deps = [":EpisodesGraphQL", "//Features/CharacterUI"],   # EpisodesGraphQL's home is "next"
)
```

**Shared code:** code that modules on both runtimes use, like networking, builds once per runtime with
`runtimes = ["current", "next"]`. Use `#if APOLLO_IOS_2` / `#else` where the APIs differ; the example's
`Networking/Network.swift` wraps the 1.x callback API and the 2.x async API behind one function.

**Using the rules directly:** the codegen targets output plain `.swift` files, which you can compile with
any Swift rule. `apollo_runtime("next")` returns the runtime's `cli`, `apollo_api`, `apollo` and
`apollo_test_support` labels. `apollo_runtime_copts("next")` returns the Apollo iOS alias flags.
In the example, `Features/Episodes` works this way:

```starlark
NEXT = apollo_runtime("next")

apollo_operations(
    name = "EpisodesGraphQL_codegen",
    srcs = [":graphql"],
    module_name = "EpisodesGraphQL",              # only exists on 2.4.0: no suffix needed
    schema = "//graphql:RickAndMortyAPI.next_apollo",
    deps = ["//Features/Characters:CharactersGraphQL.next_apollo"],
)

swift_library(
    name = "EpisodesGraphQL",
    srcs = [":EpisodesGraphQL_codegen"],
    module_name = "EpisodesGraphQL",
    copts = apollo_runtime_copts("next"),
    deps = ["//graphql:RickAndMortyAPI.next", "//Features/Characters:CharactersGraphQL.next", NEXT.apollo_api],
)
```

Only modules that exist on both runtimes need a suffix: Apollo iOS itself, the schema module, shared
libraries, and fragment owners used across the boundary. A module that only ever exists on one runtime
keeps its plain name.

## The one rule: no Apollo types across runtimes

A module on one runtime may depend on a module on the other runtime, but only through an API that doesn't
mention Apollo or generated types.

The Apollo iOS aliases apply to the whole compilation. If an Episodes file on `next` calls a 1.15 module's public
function that returns `GraphQLNullable<String>`, the compiler reads that type as `ApolloAPI_v2.GraphQLNullable`.
The build compiles, then fails to link:

```
Undefined symbols: PetsFeature.filter.unsafeMutableAddressor : ApolloAPI_v2.GraphQLNullable<Swift.String>
```

So the boundary between runtimes is made of plain Swift: models, views, closures. In the example:

- `CharacterUI` (no runtime) holds `CharacterSummary` and the row view. Each feature maps its own
  runtime's `CharacterCard` fragment to `CharacterSummary`.
- Episodes (2.4.0) opens the Characters detail screen (1.15.2) through a `characterDetail` environment
  value that the app sets. It never imports the Characters feature.
- The app module is on no runtime. It composes the features' screens.

Modular apps that already put plain models in their `Interface` modules need no changes at the boundary.

## Fragments owned by an unmigrated module

Episodes (2.4.0) spreads `CharacterCard`, which is owned by Characters (1.15.2). Its operations target
lists `//Features/Characters:CharactersGraphQL` in `deps` as usual. The 2.4.0 variant then depends on
`CharactersGraphQL_v2`, the Characters fragments generated a second time for 2.4.0. Characters doesn't
migrate first, and no `.graphql` file changes.

## Costs while two runtimes coexist

- **Two clients, two caches.** Each runtime has its own `ApolloClient` and normalized cache, so a
  mutation on one side doesn't update watchers on the other. Migrate features that share entities
  together, or refetch where they meet.
- **Size.** The app carries two Apollo runtimes, two schema modules, and second copies of fragments
  used across the boundary. The example's iOS binary is 4.6 MB with both.
- **Per-feature code changes.** 1.x → 2.x changes APIs: operations become `Sendable` structs, `Int`
  variables become `Int32`, `fetch` becomes async, and mocks' `Data.from` becomes async. Each feature
  still needs those edits, but one feature at a time.

## Finishing the migration

When every module is on `next`:

1. Remove `apollo.runtime(name = "current", ...)`, and give `next` an empty `module_suffix` (renaming it
   is optional).
2. Remove the `#else` branches of `#if APOLLO_IOS_2`.
3. Rename explicit `_v2` imports (`import Networking_v2` → `import Networking`). Only modules that used
   another runtime's variants have them, and it's a mechanical find-and-replace. `import ApolloAPI` never
   changes.

## Xcode

An earlier design aliased every module (so `import EpisodesGraphQL` reached `EpisodesGraphQL_v2`). Xcode
couldn't jump to types in generated modules reached that way, which is why only Apollo iOS is aliased now.
Verified so far: jump to definition on `GraphQLNullable` through the Apollo iOS alias, and on generated
types in unaliased modules. To check in the example: `CharacterCard` in `EpisodesScreen.swift`, which comes
from `CharactersGraphQL_v2`.

## Verified

`examples/rick_and_morty_migration`:

- builds an iOS app containing both runtimes (`ApolloAPI` and `ApolloAPI_v2` symbols side by side);
- unit tests per feature against each runtime's mocks;
- a UI test (`bazel test //UITests`, live API) that loads Characters through the 1.15.2 client and Episodes
  through the 2.4.0 client, then opens the 1.15.2 detail screen from a 2.4.0 episode;
- the rules_xcodeproj project lists both runtimes' modules, builds, and runs both runtimes' tests through
  `xcodebuild`.

Requires Swift 5.7 or later (module aliasing). Tested with Xcode 26.2 and Bazel 9.2.
