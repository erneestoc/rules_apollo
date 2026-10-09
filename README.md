# rules_apollo

Bazel rules for [Apollo iOS](https://github.com/apollographql/apollo-ios) code generation, built on the
Rust port of `apollo-ios-cli` in [erneestoc/apollo-ios-dev](https://github.com/erneestoc/apollo-ios-dev).

- **Modular apps.** One `apollo_schema` generates the shared schema-types module. Each feature has an
  `apollo_operations` target that generates only its own operations and fragments.
- **Persistent workers keyed on the schema.** Codegen runs as a Bazel worker that keeps the parsed schema in
  memory. Workers are keyed per schema, so feature targets only pay for compiling their own `.graphql` files.
- **Hermetic inputs.** The CLI only sees the files Bazel declared: exact paths, never globs. Works sandboxed.
- **Test mocks per feature.** A base mocks module plus one per feature, each type generated exactly once,
  with a test and a `bazel run` updater that keep the partition correct.
- **Migrate one module at a time.** Two Apollo iOS versions can live in one app while it migrates;
  each module picks its version ([docs/MIGRATIONS.md](docs/MIGRATIONS.md)).
- **Any Apollo version.** Prebuilt CLIs for 34 releases from 1.15.1 to 2.4.0. You can pin a version
  repo-wide, or per schema while you migrate.
- **Full configuration.** The `options` and `experimentalFeatures` keys from `apollo-codegen-config.json`
  are accepted as-is. Options that don't exist in your Apollo version fail at analysis time.

## Setup

```starlark
# MODULE.bazel
bazel_dep(name = "rules_apollo", version = "...")

apollo = use_extension("@rules_apollo//apollo:extensions.bzl", "apollo")
apollo.toolchain(version = "2.4.0")   # optional: defaults to the latest known release
```

Prebuilt CLIs are available for `aarch64-apple-darwin`, `aarch64-linux` and `x86_64-linux`, which
covers Apple Silicon and Linux remote execution. Intel Macs need a CLI built from source and
registered with `apollo_toolchain`.

The generated code is a directory of Swift files per target, which `swift_library` compiles file by
file. That needs rules_swift 4.2.0 or later, which rules_apollo depends on.

Three complete examples:
- [`examples/rick_and_morty`](examples/rick_and_morty): a modular SwiftUI app for the public Rick and Morty
  API, with rules_apple, rules_xcodeproj, per-feature modules and mocks, and simulator tests.
- [`examples/rick_and_morty_migration`](examples/rick_and_morty_migration): the same app halfway through a
  migration, with Apollo iOS 1.15.2 and 2.4.0 in one binary.
- [`examples/animal_kingdom`](examples/animal_kingdom): a smaller macOS fixture used for CI and the version
  matrix.

You also need the Apollo iOS runtime (`ApolloAPI`) as a Swift target, at the same version as the CLI. See
[the example](examples/animal_kingdom/MODULE.bazel) for a ten-line `http_archive` setup.

## Usage

```starlark
# //graphql/BUILD.bazel
load("@rules_apollo//apollo:swift.bzl", "apollo_swift_schema")

apollo_swift_schema(
    name = "MyAPI",                         # Swift module + schemaNamespace
    schema = ["schema.graphqls"],
    srcs = ["//Features/Account:graphql", "//Features/Feed:graphql"],   # every .graphql in the app
    apollo_api = "@apollo_ios//:ApolloAPI",
    custom_scalars = ["DateTime"],         # implemented in swift_srcs; others default to String
    swift_srcs = ["DateTime.swift"],
    options = {"schemaDocumentation": "exclude", "operationDocumentFormat": ["operationId"]},
    operation_manifest_version = "persistedQueries",
)
```

```starlark
# //Features/Feed/BUILD.bazel
load("@rules_apollo//apollo:swift.bzl", "apollo_swift_operations")

filegroup(name = "graphql", srcs = glob(["*.graphql"]), visibility = ["//graphql:__pkg__"])

apollo_swift_operations(
    name = "FeedGraphQL",
    schema = "//graphql:MyAPI",
    srcs = [":graphql"],
    deps = ["//Features/Account:AccountGraphQL"],   # only if you spread its fragments
    apollo_api = "@apollo_ios//:ApolloAPI",
)
```

Each macro creates a `swift_library` named `name` and a codegen target named `<name>_apollo`. If you use other
Swift rules, use `apollo_schema` / `apollo_operations` from `@rules_apollo//apollo:defs.bzl` directly. Their
default outputs are plain `.swift` files.

### Cross-module fragments

A feature lists the targets whose fragments it uses in `deps`. Their `.graphql` files are compiled so the
fragments resolve, but no code is generated for them. A generated `@_exported import` makes those
modules visible to the generated code. Fragment use across modules is checked like strict deps: spreading a
fragment from a target not listed in `deps` fails codegen with `Unknown fragment: <Name>`.

### Configuration

| Attribute | Maps to |
|---|---|
| `schema_namespace` | `schemaNamespace` (also the Swift module name) |
| `options` | `options`: any key from Apollo's docs. `pruneGeneratedFiles` and `cocoapodsCompatibleImportStatements` are managed by the rules |
| `experimental_features` | `experimentalFeatures` |
| `operation_manifest_version` | `operationManifest` (output group `operation_manifest`) |
| `apollo_operations.access_modifier` | `output.operations.absolute.accessModifier` |
| `schema_configuration` | Your `SchemaConfiguration.swift`, replacing the generated default |
| `custom_scalars` | Custom scalars you implement yourself. The CLI's default `typealias <Name> = String` is dropped for them |

`input` and `output` are owned by the rules.

### Test mocks

```starlark
# //graphql/BUILD.bazel: shared mocks and the MockObject typealiases
apollo_swift_test_mocks(
    name = "MyAPIMocks",
    schema = ":MyAPI",
    types = [...],           # maintained by the updater below
    exclude_types = [...],
    apollo_api = "@apollo_ios//:ApolloAPI",
    apollo_test_support = "@apollo_ios//:ApolloTestSupport",
)

apollo_swift_mock_partition(
    name = "mock_partition_test",
    base = ":MyAPIMocks",
    feature_mocks = ["//Features/Feed:FeedTestSupport"],
)

# //Features/Feed/BUILD.bazel: mocks only Feed references
apollo_swift_test_mocks(
    name = "FeedTestSupport",
    schema = "//graphql:MyAPI",
    base = "//graphql:MyAPIMocks",
    operations = [":FeedGraphQL"],
    apollo_api = "@apollo_ios//:ApolloAPI",
    apollo_test_support = "@apollo_ios//:ApolloTestSupport",
)
```

A type referenced by exactly one feature is generated in that feature's module. Anything else goes in
the base. `bazel test //graphql:mock_partition_test` fails if a type is generated twice or is missing,
or if the declared lists are stale. `bazel run //graphql:mock_partition_test_update` rewrites the lists.
See [docs/MOCKS.md](docs/MOCKS.md).

### Pinning a version per schema

```starlark
# MODULE.bazel
apollo.toolchain(name = "apollo_next", version = "2.4.0")
use_repo(apollo, "apollo_next")

# BUILD
apollo_swift_schema(name = "MyAPI", cli = "@apollo_next//:cli", ...)
```

Operations always use their schema's version. A mismatch with the registered toolchain is an analysis
error.

### Two Apollo versions while migrating

```starlark
# MODULE.bazel
apollo.runtime(name = "current", version = "1.15.2")
apollo.runtime(name = "next", version = "2.4.0", module_suffix = "_v2")

# A feature's BUILD file
apollo_swift_library(name = "EpisodesFeature", runtime = "next", runtime_deps = [":EpisodesGraphQL"], ...)
```

rules_apollo builds both Apollo iOS versions, generates code for each, and compiles each module against
its runtime with Swift module aliases. Code keeps saying `import ApolloAPI`. See
[docs/MIGRATIONS.md](docs/MIGRATIONS.md) for the setup and the one rule to follow.

### Workers

Codegen actions support singleplex and multiplex workers. Recommended `.bazelrc`:

```
build --strategy=ApolloCodegen=worker,sandboxed
```

Each schema gets one worker process that parses the schema once and serves concurrent requests for schema
types, operations and mocks. A typical feature takes milliseconds. `--worker_sandboxing` is supported;
Bazel then uses sandboxed singleplex workers.

## Design and roadmap

See [docs/DESIGN.md](docs/DESIGN.md). It covers the versioning trade-offs, measured invalidation behavior,
options for splitting the schema module, CLI issues, and the roadmap. Test mocks are specified in
[docs/MOCKS.md](docs/MOCKS.md).

## Development

```sh
bazel test //...                                       # analysis tests + real codegen (incl. a 2.3.0 pin)
(cd examples/animal_kingdom && bazel test //...)       # codegen, Swift compile/link/run, mocks, partition
tools/version_matrix.sh 1.15.1 2.0.3                   # the example end to end against other Apollo versions
tools/update_versions.sh                               # refresh CLI checksums after fork releases
```

## License

MIT. See [LICENSE](LICENSE). The GraphQL fixtures in `examples/animal_kingdom` come from
[apollo-ios](https://github.com/apollographql/apollo-ios) (MIT).
