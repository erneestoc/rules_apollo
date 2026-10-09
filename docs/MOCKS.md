# Test mocks per feature (`apollo_test_mocks`)

Roadmap item 6 of [DESIGN.md](DESIGN.md). Status: the CLI side is implemented on every release
branch of the fork (`<ver>-rust-parity`, 1.15.1 through 2.4.0; scoped test mocks, Bazel `test_mocks`
mode), released on 2026-10-04. The rules side is implemented as specified here, with the deviations
listed in [§8](#8-implementation-status). This document specifies what the CLI offers and how the rules use it.

> **Fixed (fork releases of 2026-10-04, second mocks release):** under `--bazel-output-dir`, generated
> mocks used to have an empty `MockFields`. Every `<ver>-rust-parity` release now builds the IR of every
> compiled operation and fragment before generating mocks, so Bazel-mode mocks (`test_mocks` and
> `schema_types`, with or without a selection, one-shot and worker) are verified byte-identical to plain
> `generate` and to the Swift CLI (see §2.5). A mocks action must still compile **all** operations (§2.4).

Goal (user's words): *"the goal is not to have TestSupport always have all the mocks, but let each
module compile a subset of the total mocks in the project."* Module layout to support:
`Framework/{Impl, Interface, Tests, TestSupport}`, where a feature's mocks live in the feature's
`TestSupport`, shared mocks live in one base `TestSupport` module, and it all composes.

## 1. Background: how Apollo generates test mocks

* Apollo iOS generates one `<Object>+Mock.graphql.swift` per **object type referenced by some
  operation**, plus two typealias files, `MockObject+Interfaces.graphql.swift` and
  `MockObject+Unions.graphql.swift` (`public extension MockObject { typealias Animal = Interface }`),
  into exactly one `output.testMocks` location.
* A mock's fields are the **union of the fields selected on that type by every operation the CLI
  compiled** (`@Field<Human>("owner") public var owner`), so the file content depends on the whole
  app's operations, not on the feature's.
* Mock files reference other mocks by type (`@Field<Human>`, `Mock<Height>?`) and the typealiases by
  bare name (`@Field<[Animal]>` resolves to `MockObject.Animal`). The runtime (`ApolloTestSupport`'s
  `Mock<T>`, `MockObject`, `MockFields`) does not care which Swift module a mock lives in. So a mock
  can live in any module as long as the modules holding the mocks it mentions, and the typealiases,
  are imported.
* "Referenced" follows graphql-js's `addReferencedType`: a selected object adds its interfaces, an
  interface adds **all of its implementing objects**, a union adds its members. Selecting
  `allAnimals { id }` on `[Animal]` therefore references every `Animal` implementor.

## 2. What the CLI offers (fork, every `<ver>-rust-parity` branch 1.15.1-2.4.0)

Everything below generates **byte-identical files** to Apollo's for a given type, in Bazel mode as well
as plain `generate` (§2.5). Only the selection of types, the optional `import <baseModule>` line and
the presence of the typealias files change. The unscoped output is unchanged (the parity harness
stays at 0 differing files).

### 2.1 Configuration keys

`output.testMocks` accepts, inside both the `absolute` and the `swiftPackage` objects:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `scope` | `"all"` \| `"referencedByOperations"` | `"all"` | `all`: every object type referenced by any operation the config sees (Apollo's behaviour). `referencedByOperations`: only the types referenced by the operations and fragments **selected for generation** (every definition outside Bazel mode; the `--bazel-generate-for` / `--bazel-framework-path` selection in Bazel mode), expanded through interfaces/unions as in §1. |
| `includeTypes` | `[String]` | `[]` | Always generated. Each name must be an object type referenced by some operation of the config, otherwise the CLI fails (`includeTypes names 'X', which is not an object type referenced by any operation`). |
| `excludeTypes` | `[String]` | `[]` | Never generated. Unknown names are ignored, so one list (the base's types) can be reused by every feature. |
| `baseModule` | `String` | unset | Module that holds the shared mocks and the typealiases. Every generated mock file gets a third import line, `import <baseModule>`, after `import ApolloTestSupport` / `import <SchemaModule>`. |
| `includeTypealiases` | `Bool` | `true` without `baseModule`, `false` with it | Whether `MockObject+Interfaces` / `MockObject+Unions` are generated. They always list **every** interface/union referenced by the whole config, so exactly one module of a partition must carry them. |

Effective set: `selected = scope ∪ includeTypes − excludeTypes`, emitted in Apollo's referenced-type
order. Unknown keys inside the inner objects are ignored, as Swift's `Codable` does; unknown variant
keys (`{"scoped": …}`) and unknown `output` keys are rejected as before.

```json
"testMocks": {
  "swiftPackage": {
    "targetName": "AccountMocks",
    "scope": "referencedByOperations",
    "excludeTypes": ["Query", "Human", "Height"],
    "baseModule": "AnimalKingdomBaseMocks"
  }
}
```

### 2.2 Bazel flags

| Flag | Repeatable | Overrides config key | Semantics |
|---|---|---|---|
| `--bazel-mode test_mocks` | | | New mode: writes **only** the test mock files, under `<--bazel-output-dir>/TestMocks/`, nothing else. `schema_types` mode keeps writing schema types plus mocks under `TestMocks/` when `testMocks` is configured, and also honours the flags below. |
| `--bazel-mocks-scope all\|referenced` | | `scope` | `referenced` = `referencedByOperations`, evaluated against the `--bazel-generate-for` / `--bazel-framework-path` selection (without a selection it equals `all`). |
| `--bazel-mocks-for <TypeName>` | yes | `includeTypes` | Replaces the config list. |
| `--bazel-mocks-exclude <TypeName>` | yes | `excludeTypes` | Replaces the config list. |
| `--bazel-mocks-base-module <Module>` | | `baseModule` | |
| `--bazel-mocks-typealiases true\|false` | | `includeTypealiases` | |

Rules: the flags and `test_mocks` mode require `--bazel-output-dir` and a configured test mock output
(`absolute` or `swiftPackage`; with `none` the CLI fails with
`--bazel-mode test_mocks and the --bazel-mocks-* flags require 'output.testMocks' to be 'absolute' or
'swiftPackage'`). The flags work identically through the persistent worker (they are request
arguments; the compilation cache is keyed on config + inputs and is unaffected because the flags only
change generation). `--bazel-strip-import` and the other post-processing flags apply to the mock
files too. `apollo-ios-cli generate --help` documents the flags under "Bazel test mocks".

### 2.3 Example invocations and layouts

Config (`rules_apollo` style, exact input paths, written by the rule):

```json
{
  "schemaNamespace": "AnimalKingdomAPI",
  "input": { "schemaSearchPaths": ["graphql/AnimalSchema.graphqls"],
             "operationSearchPaths": ["Features/Pets/PetsQuery.graphql", "Features/Adopt/Adopt.graphql", "..."] },
  "output": { "schemaTypes": {"path": ".", "moduleType": {"other": {}}},
              "operations": {"absolute": {"path": "."}},
              "testMocks": {"absolute": {"path": "TestMocks", "accessModifier": "public"}} }
}
```

Base module (every type except the feature-owned ones, plus the typealiases):

```
apollo-ios-cli generate --string "$CONFIG" --bazel-output-dir out/base --bazel-mode test_mocks \
  --bazel-mocks-exclude Query --bazel-mocks-exclude Mutation
out/base/TestMocks/Bird+Mock.graphql.swift … Rat+Mock.graphql.swift
out/base/TestMocks/MockObject+Interfaces.graphql.swift
out/base/TestMocks/MockObject+Unions.graphql.swift
```

Feature module (its referenced types minus the base's, importing the base):

```
apollo-ios-cli generate --string "$CONFIG" --bazel-output-dir out/pets --bazel-mode test_mocks \
  --bazel-mocks-scope referenced \
  --bazel-generate-for Features/Pets/PetsQuery.graphql --bazel-generate-for Features/Pets/PetBits.graphql \
  --bazel-mocks-exclude Bird --bazel-mocks-exclude Cat … --bazel-mocks-exclude Rat \
  --bazel-mocks-base-module AnimalKingdomBaseMocks
out/pets/TestMocks/Query+Mock.graphql.swift      # import ApolloTestSupport / import AnimalKingdomAPI / import AnimalKingdomBaseMocks
```

Unscoped reference (what a single TestSupport gets today): `--bazel-mode schema_types` (or
`test_mocks` without flags) → `out/all/TestMocks/*`. The union of base and features equals this set,
file for file, except for the `import <baseModule>` line in feature files.

### 2.4 Inputs must be the whole app's operations

Because a mock's fields are collected from every compiled operation (§1), **a mocks action must
compile the same operation set as `apollo_schema`** (every `.graphql` of the app) and use
`--bazel-generate-for` only to pick the scope. Giving a feature's mocks action only the feature's
files would produce a `Dog+Mock` with fewer fields than the base's, and the union would no longer
equal the unscoped output. This is the same input set the schema target already has, so the cost is
an extra worker request per mocks target (the parsed schema and the compilation are cached per
config + inputs in the multiplex worker; a feature request after the first one is ~10 ms). The CLI
does its part: in `test_mocks` and `schema_types` mode it builds the IR of every operation and
fragment it compiled (not only the selected ones) before collecting the fields, so the selection
only ever decides which mock *files* a module gets, never their content.

### 2.5 Bazel-mode mocks are byte-identical to plain `generate` and to Swift

The first mocks release (2026-10-04) shipped with empty `MockFields` under `--bazel-output-dir`:
the field collector is filled while an operation's IR is built, and the Bazel modes that render no
operations never built it. The second release fixes this on every branch 1.15.1-2.4.0 and verifies,
per version, that the mocks written by `--bazel-mode test_mocks` and `schema_types` (without a
selection, with `--bazel-generate-for`, with `--bazel-framework-path`, with
`--bazel-mocks-scope referenced`, with a base module, one-shot and through the persistent worker
after a cached compilation) are byte-identical, file for file, to plain `generate` **and** to the
official Swift CLI's mocks on AnimalKingdom and KitchenSink (`mocks-bazel.sh`, 16 cases per version;
`mocks-compat.sh` and `mocks-split.sh` now compare their Bazel outputs to plain/Swift too; a CLI
integration test in `codegen-cli/tests/bazel_integration_tests.rs` covers the same incl. the worker).
`Mock<Dog>` has its fields (12 on the 1.15.1 fixture, 13 from upstream 2.0.3, which selects `adoptionDate`) and the `convenience init` in every mode. The same fix switched off
`pruneGeneratedFiles` under `--bazel-output-dir` in the one-shot CLI (the worker already had it off):
pruning walked the *configured* output paths relative to the cwd (the execroot) and deleted every
`*.graphql.swift` it found there that the run had not written.

## 3. Partition algorithm (what the rules implement)

Definitions, per `apollo_schema`:

* `All` = object types referenced by any operation (what `scope: all` generates).
* `Ref(F)` = object types referenced by feature `F`'s operations and fragments
  (`--bazel-mocks-scope referenced` on `F`'s srcs), interface/union expansion included.
* `Shared` = types referenced by the shared schema shard (DESIGN.md "schema sharding"), when sharding
  is used: fragments and operations that are not owned by any feature.

Rules:

1. **Base** = `{ t ∈ All : t ∈ Ref(F) for more than one F }` ∪ `Shared` ∪ `{ t ∈ All : t ∉ Ref(F) for
   every F }` ∪ the `MockObject+Interfaces` / `MockObject+Unions` typealias files. In words: anything
   two features both need, anything the shared shard needs, anything nobody selects explicitly
   (e.g. types only reached through a shared fragment), and always the typealiases.
2. **Feature(F)** = `Ref(F) − Base`: the types exclusive to `F`.
3. Every feature `TestSupport` depends on the base `TestSupport` (`import <Base>` is in the generated
   files; the Swift dependency must exist).
4. **No overrides, no conflicts.** A type is generated by exactly one module. Two features cannot both
   own a type (then it belongs to the base), and a feature cannot re-generate a base type with
   different fields (there are no "different fields": every module sees the same operations, §2.4).
   Overlaps are rejected by validation (§6), never resolved silently.
5. Interface expansion makes shared families collapse into the base: in AnimalKingdom every
   `Animal`/`Pet` implementor is in `Ref(F)` of any feature that selects `allAnimals`, so the base
   holds all animals and the features own only `Query` / `Mutation`. That is the correct answer for
   that schema; schemas with disjoint type families (accounts vs. catalog vs. checkout) partition
   much better.
6. **Closure under field references.** Mocks name other mocks in their fields (`Dog` has
   `@Field<Height>("height")`). The base cannot import a feature, and features cannot import each other.
   So a type named by a base mock, or by a mock another feature owns, belongs to the base, repeated
   until nothing changes. A feature keeps only types reached from its own mocks or from no mock at all.
   In AnimalKingdom, `Height` is selected only by Animals, but the base's `Dog` names it, so it lives
   in the base. Without this rule the base mocks module does not compile ("cannot find type 'Height'").
   The edges come from the unscoped reference mocks, so the rule needs no extra CLI support.

Where the sets come from. `Ref(F)` is a build-time result of the CLI, and Bazel rules cannot read
action outputs at analysis time. Two workable designs; the second is recommended:

* **Computed, declared ownership.** The base target declares `types = [...]` (its owned types) and
  features declare nothing: a feature's action runs with `--bazel-mocks-scope referenced` and
  `--bazel-mocks-exclude <base.types…>`, so `Feature(F) = Ref(F) − base.types` exactly, with no
  BUILD edits when a feature adds a type nobody else uses. A `bazel run //graphql:update_mock_partition`
  target (or the Gazelle extension of roadmap item 1) recomputes `base.types` from the current
  operations, and `apollo_mock_partition_test` (§6) fails the build when the declared base is stale
  (a type shared by two features is missing from it, or a base type is referenced by no one).
* **Fully declared.** Every target lists its `types`. Simpler rules, more BUILD churn; every new type
  needs an edit. Not recommended beyond small apps.

With the recommended design the rules pass, per target:

| Target | `--bazel-mode` | scope | include | exclude | base module | typealiases |
|---|---|---|---|---|---|---|
| base | `test_mocks` | `all` | `types` (optional, validated) | every type owned by a feature (= `exclude_types`, see below) | — | yes (default) |
| feature | `test_mocks` | `referenced` on the feature's `srcs` | `types` (optional) | `base.types` | base's `module_name` | no (default) |

The base cannot know the features (dependencies point the other way), so it cannot compute
"everything minus what features own" by itself. The base target therefore carries two declared
lists, both written by the updater and both checked by the partition test:

* `types`: the types the base owns. Flows through `ApolloTestMocksInfo` into every feature's
  `--bazel-mocks-exclude` list.
* `exclude_types`: the feature-owned types. Passed as the base's own `--bazel-mocks-exclude` list with
  `scope: all`, so the base generates `All − exclude_types`.

`types` is informative for the base's own action (`--bazel-mocks-for` only validates that each name is
referenced); the generated set is `All − exclude_types`. The partition test checks that
`types ∪ exclude_types == All`, that no `exclude_types` entry is in `Ref(F)` of more than one feature
and that every `types` entry is either shared or unselected (§6).

## 4. Proposed rule API

### 4.1 `apollo_test_mocks` (private/test_mocks.bzl)

```python
apollo_test_mocks(
    name,                 # codegen target; outputs a directory of generated .swift files
    schema,               # label: apollo_schema (ApolloSchemaInfo). Mandatory.
    base = None,          # label: the base apollo_test_mocks (ApolloTestMocksInfo). None => this target IS the base.
    operations = [],      # labels: apollo_operations targets whose srcs define the `referenced` scope (features only).
    srcs = [],            # .graphql files to add to the scope (features only; rarely needed with `operations`).
    types = [],           # explicit includeTypes. Base: the owned types (feeds features' exclusions). Feature: extra types.
    exclude_types = [],   # base only: feature-owned types the base must not generate (written by the updater).
    module_name = None,   # Swift module the mocks compile into; defaults to name. Becomes `baseModule` for dependants.
    access_modifier = "public",
    testonly = True,
)
```

Implementation outline:

```python
def _apollo_test_mocks_impl(ctx):
    schema = ctx.attr.schema[ApolloSchemaInfo]
    cli = resolve_cli_pinned_to_schema(ctx, schema)          # as apollo_operations does
    out = ctx.actions.declare_directory(ctx.label.name + "_test_mocks")
    operation_files = schema.operation_files.to_list()       # NEW provider field, see 4.3: every .graphql of the app
    config = codegen_config(schema.config, schema.schema_files.to_list(), operation_files,
                            access_modifier = ctx.attr.access_modifier,
                            test_mocks = {"absolute": {"path": "TestMocks", "accessModifier": ctx.attr.access_modifier}})
    args = codegen_args(ctx, config, out, mode = "test_mocks")
    if ctx.attr.base:
        base = ctx.attr.base[ApolloTestMocksInfo]
        if base.schema != schema.label: fail(...)
        args.add("--bazel-mocks-scope", "referenced")
        for f in scope_files(ctx):                            # operations[*].srcs + srcs, exact paths
            args.add("--bazel-generate-for", f.path)
        args.add_all(base.types, before_each = "--bazel-mocks-exclude")
        args.add("--bazel-mocks-base-module", base.module_name)
    else:
        args.add_all(ctx.attr.exclude_types, before_each = "--bazel-mocks-exclude")
    args.add_all(ctx.attr.types, before_each = "--bazel-mocks-for")
    ctx.actions.run(executable = cli.cli, arguments = [args],
                    inputs = depset(transitive = [schema.schema_files, schema.operation_files]),
                    outputs = [out], mnemonic = "ApolloTestMocks",
                    execution_requirements = codegen_execution_requirements(),
                    env = worker_env(schema.label), ...)
    return [
        DefaultInfo(files = depset([out, module_placeholder(ctx)])),
        OutputGroupInfo(generated_tree = depset([out])),
        ApolloTestMocksInfo(schema = schema.label, module_name = module_name, base = base_label_or_None,
                            types = ctx.attr.types, exclude_types = ctx.attr.exclude_types,
                            generated_tree = out),
    ]
```

`codegen_config` gains a `test_mocks` parameter (today it hard-codes `{"none": {}}`); `codegen_args`
accepts `mode = "test_mocks"`.

### 4.2 Providers

```python
ApolloTestMocksInfo = provider(fields = {
    "schema": "Label of the apollo_schema.",
    "module_name": "Swift module the mocks compile into (the `baseModule` of dependants).",
    "base": "Label of the base apollo_test_mocks, or None for the base itself.",
    "types": "list[string]: declared owned types (base) or extra includes (feature).",
    "exclude_types": "list[string]: base only, feature-owned types.",
    "generated_tree": "File: the TestMocks tree artifact (for apollo_mock_partition_test).",
})
```

### 4.3 Changes to existing rules

* `ApolloSchemaInfo` gains `operation_files: depset[File]` (the schema target's `srcs`), so mocks
  targets compile the whole app's operations (§2.4) without re-declaring them.
* `apollo_swift_test_mocks` macro (swift.bzl): `apollo_test_mocks` + `swift_library(testonly = True,
  module_name = …, deps = [schema module, ApolloTestSupport, base swift_library])`, mirroring
  `apollo_swift_operations`.
* `apollo_mock_partition_test` (§6).

### 4.4 Example BUILD files

Base, next to the schema (`//graphql`):

```python
load("@rules_apollo//apollo:swift.bzl", "apollo_swift_mock_partition", "apollo_swift_schema", "apollo_swift_test_mocks")

apollo_swift_schema(
    name = "AnimalKingdomAPI",
    schema = ["AnimalSchema.graphqls"],
    srcs = ["//Features/Pets:graphql", "//Features/Adopt:graphql"],   # every .graphql of the app
    apollo_api = "@apollo_ios//:ApolloAPI",
    visibility = ["//visibility:public"],
)

apollo_swift_test_mocks(
    name = "AnimalKingdomAPIMocks",          # module AnimalKingdomAPIMocks: shared mocks + typealiases
    schema = ":AnimalKingdomAPI",
    apollo_api = "@apollo_ios//:ApolloAPI",
    apollo_test_support = "@apollo_ios//:ApolloTestSupport",
    types = ["Bird", "Cat", "Crocodile", "Dog", "Fish", "Height", "Human", "PetRock", "Rat"],  # maintained by the updater
    exclude_types = ["Query", "Mutation"],                                                     # feature-owned
    visibility = ["//Features:__subpackages__"],
)

apollo_swift_mock_partition(                  # creates :mock_partition_test and :mock_partition_test_update
    name = "mock_partition_test",
    base = ":AnimalKingdomAPIMocks",
    feature_mocks = ["//Features/Pets:PetsTestSupport", "//Features/Adopt:AdoptTestSupport"],
)
```

Feature `//Features/Pets` with the `Framework/{Impl, Interface, Tests, TestSupport}` layout:

```python
# Features/Pets/BUILD.bazel
load("@rules_apollo//apollo:swift.bzl", "apollo_swift_operations", "apollo_swift_test_mocks")

filegroup(name = "graphql", srcs = glob(["*.graphql"]), visibility = ["//graphql:__pkg__"])

apollo_swift_operations(                      # Interface-level generated code: PetsGraphQL
    name = "PetsGraphQL",
    srcs = [":graphql"],
    schema = "//graphql:AnimalKingdomAPI",
    apollo_api = "@apollo_ios//:ApolloAPI",
    visibility = ["//visibility:public"],
)

swift_library(name = "PetsInterface", srcs = glob(["Interface/**/*.swift"]), deps = [":PetsGraphQL"])
swift_library(name = "PetsImpl", srcs = glob(["Impl/**/*.swift"]), deps = [":PetsInterface"])

apollo_swift_test_mocks(                      # PetsTestSupport: only the mocks exclusive to Pets
    name = "PetsTestSupport",
    schema = "//graphql:AnimalKingdomAPI",
    base = "//graphql:AnimalKingdomAPIMocks",
    operations = [":PetsGraphQL"],             # scope = types referenced by Pets' operations
    swift_srcs = glob(["TestSupport/**/*.swift"]),   # hand-written helpers compiled into the same module
    apollo_api = "@apollo_ios//:ApolloAPI",
    apollo_test_support = "@apollo_ios//:ApolloTestSupport",
    visibility = ["//Features:__subpackages__"],
)

swift_test(
    name = "PetsTests",
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":PetsImpl", ":PetsTestSupport", "//graphql:AnimalKingdomAPIMocks"],
)
```

Generated module contents for this example (AnimalKingdom, Apollo 1.15.1):

```
AnimalKingdomAPIMocks/   Bird+Mock Cat+Mock Crocodile+Mock Dog+Mock Fish+Mock Height+Mock Human+Mock
                         PetRock+Mock Rat+Mock MockObject+Interfaces MockObject+Unions
PetsTestSupport/         Query+Mock            (imports AnimalKingdomAPIMocks)
AdoptTestSupport/        Mutation+Mock         (imports AnimalKingdomAPIMocks)
```

## 5. How deps and visibility flow

* `PetsTestSupport` → `AnimalKingdomAPIMocks` → `AnimalKingdomAPI` + `ApolloTestSupport`. The macro
  adds the base `swift_library` to the feature's deps automatically (the generated files import it).
* Tests of a feature depend on the feature's `TestSupport` and on the base (transitively available,
  but Swift needs the direct import to use base mocks by name, so list it).
* A test that needs another feature's mocks (`Mock<Mutation>` from Adopt inside Pets' tests) depends
  on that feature's `TestSupport`; both can be linked into one test binary because their types are
  disjoint. Linking two modules that both generated the same type is a duplicate-class error, which is
  exactly what the partition test prevents earlier.
* Visibility: the base is visible to every feature package; feature `TestSupport`s are visible to
  the feature's tests and to whoever legitimately composes them. `testonly = True` on every mocks
  target keeps mocks out of production binaries.
* Access control: generated with `accessModifier: public` (the default for `absolute`), required
  across modules. `internal` only makes sense when the mocks and the tests are one module.

## 6. Validation: the union-equals-all check

`apollo_mock_partition_test(name, base, features)` is a test rule with one action and one test script:

1. Action `ApolloTestMocksReference`: run the CLI once with the same config and inputs as the base,
   `--bazel-mode test_mocks` and **no** scoping (that is the unscoped output every TestSupport gets
   today), into a tree artifact `reference/`.
2. The test script (`sh_test` with the base's, every feature's and the reference tree artifact as
   data) checks, like `mocks-split.sh` in the fork's parity tools:
   * no file name appears in more than one module (duplicate type);
   * `base ∪ features == reference` as a set of file names (no type lost, none invented);
   * every file is byte-identical to the reference after removing the single `import <base module>`
     line from feature files;
   * feature modules contain no `MockObject+*` file; the base contains both (when the schema has
     interfaces/unions).
3. On failure it prints the fix: "types shared by several features must move to the base: …" /
   "base types referenced by no feature: …" / "stale base.types: run `bazel run //graphql:update_mock_partition`".

Keep the test in the schema package and in CI; it is cheap (one extra worker request, file diffs).

The fork's parity harness runs the same check end to end for every version (`mocks-split.sh`:
generation through the CLI, the union check, a SwiftPM package with `BaseMocks`, `FeatureAMocks`,
`FeatureBMocks` and one XCTest target each, `swift build` + `swift test`), plus `mocks-compat.sh`
(Swift CLI mocks vs Rust CLI mocks compiled side by side with an XCTest asserting identical
behaviour), each against the Apollo iOS runtime of that version, and `mocks-bazel.sh` (every Bazel
mode/selection's mocks byte-identical to the Swift CLI's, §2.5). All three pass on all 34 versions
1.15.1-2.4.0.

## 7. Limits and open questions

* **Inputs.** Every mocks target sees every operation (§2.4), so editing any `.graphql` re-runs all
  mocks actions. Outputs are byte-identical unless the edit touched a selected field of a mocked
  type, so Bazel's early cutoff keeps Swift recompiles to the affected module(s). This is the same
  trade-off `apollo_schema` already makes.
* **Partition quality** depends on the schema: interface/union expansion pulls whole families into
  the base (§3.5). Expect the base to be large for "everything implements Node" schemas; the win is
  then mostly that features compile only their root/payload types and their tests link less.
* **The shared root type collapses the partition (measured).** The closure rule (§3.6) has a strong
  consequence. If two features run queries, `Query` is shared, so its mock lives in the base. Its fields
  name the mock of every type a query returns, and those mocks name the next level, until every type
  reachable from any selected `Query` field is in the base. A feature can only own types that are
  reachable solely through a root it alone uses, e.g. the only feature with mutations owning `Mutation`
  and its payloads (AnimalKingdom's `Mutation` in Pets). `examples/rick_and_morty`, with three features
  that all query, ends with all 8 types in the base and empty feature `TestSupport` modules.

  So per-feature mocks, as designed, mostly don't reduce what a feature's tests compile. The base still
  works as the single shared mocks module. Making features own types needs the shared mocks to stop
  naming them concretely. One option: generate root and shared mocks with fields typed by interface
  (`Mock<some MockObject>`) rather than concrete mock classes, so a feature can supply its own types
  without the base importing it. That is a CLI template change and a deeper design question. Until then,
  the base module plus the partition test is the realistic setup.
* **Ownership is declared** (`base.types`, `base.exclude_types`) because analysis cannot see
  `Ref(F)`. The updater and the partition test keep it honest. A future CLI mode that emits a
  JSON ownership manifest (per-file referenced sets) would let the updater avoid parsing file names.
* **Typealiases live in the base.** A feature whose mocks mention an interface (`@Field<[Animal]>`)
  needs the base even if it owns every object type involved. With `includeTypealiases: true` a feature
  could carry its own copy, but two modules both extending `MockObject` with the same typealias is an
  ambiguity at use sites. Rule: only the base generates them.
* **Schema sharding** (DESIGN.md): the shared shard's types belong to the base by definition; a feature
  shard's exclusive types may stay in the feature.
* **Version differences (all branches carry the feature).** The selection logic, config keys and
  flags are identical on every branch; only the mock templates differ. 1.24.0+ imports the schema
  module with `@testable import <Schema>` in mock files, so a feature mock module needs the schema
  module built with testing enabled (as any mock module does today) and the `import <baseModule>`
  line follows it. 2.0.0+ mocks are `final class` with `struct MockFields: Sendable` and compile
  against the Swift 6 runtime (Apollo iOS 2.x is `swift-tools-version:6.1`, language mode 6);
  2.0.3+ use `.defaultMockValue` for custom scalars; 2.1.0+ render `nonisolated` on the generated
  declarations (`markTypesNonisolated`). None of this changes how the rules invoke the CLI. For
  hand-written test helpers on 2.x: `DataDict` / `SelectionSet.__data` are `@_spi(Unsafe)` (import
  `ApolloAPI` with `@_spi(Unsafe)` to read `__data._data`) and `RootSelectionSet.from(mock)` is
  `async`. The typealias gating is identical across versions.
* **Open:** should `apollo_test_mocks` also accept hand-written mock helpers (`srcs`) or should those
  stay in a sibling `swift_library` that depends on the generated one? The macro form above merges
  them; keeping them separate makes the generated module trivially regenerable.
* **Open:** `apollo_schema(srcs = …)` is the source of truth for "every operation". With Gazelle
  (roadmap item 1) the mocks `operations` attr and the base `types`/`exclude_types` lists should be
  generated too.

## 8. Implementation status

Implemented in `apollo/private/test_mocks.bzl`, `apollo/private/mock_partition.sh` and
`apollo/swift.bzl`. It is exercised by `examples/animal_kingdom`: a base module, two feature modules, the
partition test, and Swift tests that link mocks from several modules. The analysis tests are in
`tests/analysis`.

Deviations from the proposal above:

* **Mnemonic.** Mocks actions use `ApolloCodegen`, not `ApolloTestMocks`. Bazel keys workers by
  mnemonic, so a separate mnemonic would start a separate worker that parses the schema again.
* **`feature_mocks`, not `features`.** `features` is a reserved attribute on every Bazel rule. The
  partition rules and the `apollo_swift_mock_partition` macro take `feature_mocks`.
* **The base's `types` are not passed as `--bazel-mocks-for`.** A stale entry (a type no longer referenced)
  would fail the base's codegen, and so the build, before the partition test could explain the fix. The
  base generates `All − exclude_types`, and the partition test checks `types`. A feature's `types` are
  still passed as `--bazel-mocks-for`, since they are an explicit request.
* **Closure rule (§3.6).** It was added once mocks had fields: the base module didn't compile with the
  proposal's partition. The partition test and the updater both compute it.
* **Updater.** `apollo_swift_mock_partition(name = ...)` creates `<name>` (the test) and `<name>_update`.
  `bazel run //graphql:mock_partition_test_update` rewrites the base's `types`/`exclude_types` with
  buildozer, a dependency of rules_apollo from the registry, so nothing needs installing. It only builds the
  reference sets, so a stale declaration that breaks the base or a feature never blocks it.
* **Macro `srcs`.** In `apollo_swift_test_mocks`, `srcs` are `.graphql` scope files (as on the rule), and
  hand-written Swift helpers go in `swift_srcs`. This answers the open question in §7: helpers are merged
  into the generated module.
