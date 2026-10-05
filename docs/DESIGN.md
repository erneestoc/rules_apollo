# rules_apollo design

## Architecture

```
                      ┌──────────────────────────────┐
 schema.graphqls ───▶ │ apollo_schema  (MyAPI)       │──▶ MyAPI.swiftmodule (schema types)
 ALL *.graphql   ───▶ │  mode=schema_types           │──▶ operation manifest (optional)
                      └──────────────┬───────────────┘
                                     │ ApolloSchemaInfo (namespace, options, version)
              ┌──────────────────────┼───────────────────────┐
              ▼                      ▼                       ▼
   apollo_operations (Pets)   apollo_operations (Animals) ─deps─▶ Pets (fragments)
   inputs: own srcs           inputs: own srcs + Pets srcs
   generates: own srcs        generates: own srcs only, + `@_exported import PetsGraphQL`
```

* **Schema module.** It sees every `.graphql` file because Apollo generates only the schema types that some
  operation references.
* **Feature modules.** They see only their own files plus the files of their `deps`. Code is generated
  only for their own files, selected exactly with one `--bazel-generate-for <file>` per source.
* **Test mocks.** `apollo_test_mocks` targets partition the mocks into a base module and per-feature
  modules. See [MOCKS.md](MOCKS.md).
* **Config.** The rules build the whole `apollo-codegen-config.json` at analysis time. `input` holds the
  exact `File.path`s Bazel declared, and the config is passed with `--string` in a params file. The CLI
  never globs the source tree.
* **Outputs.** The CLI writes a tree artifact. A small `ApolloShard` action packs it into a fixed number of
  declared `.swift` files (hashed by path), because Swift rules don't handle directory sources well.
  `rules_swift` declares one `.o` per source `File`, and a tree artifact is one `File`. With shards, Swift
  compiles in parallel, and adding a type rewrites one shard.

### Persistent workers

The fork's CLI implements the worker protocol (`--persistent_worker`), including multiplex. One worker
process serves concurrent requests from a shared parsed schema. Its compilation cache is keyed on the config
text plus the schema and operation digests, and holds 8 entries.

Actions declare `supports-workers` and `supports-multiplex-workers`. The CLI ignores
`WorkRequest.sandbox_dir`, so they do not declare `supports-multiplex-sandboxing`. With `--worker_sandboxing`,
Bazel falls back to sandboxed singleplex workers.

Bazel keys workers on `(mnemonic, startup args, env, tool digest)`. Each codegen action sets
`APOLLO_WORKER_SCHEMA=<schema label>` in its env, which gives every schema its own worker. Schema types,
operations and mocks all use the `ApolloCodegen` mnemonic, so they share that worker.

Measured on the example from a clean build: one multiplex process served all 12 codegen requests (schema
types, two operation modules, mocks and the partition test's reference sets) and parsed the schema once.
A feature request after the first takes about 10 ms. The real schema parse cost only appears on large
schemas; the fork's notes cite about 5 s.

## Q: should the Apollo version be configurable per module, or should there be rules per version?

**Recommendation: one ruleset where the version is data, selected through a toolchain. The unit of
versioning is the schema, not the Swift module.**

| | Rules per version (`rules_apollo_1`, `rules_apollo_2`…) | Version per module/target | Version per schema via toolchain (chosen) |
|---|---|---|---|
| Upgrading | Rewrite every `load()` and BUILD file | Edit N targets, easy to leave stragglers | Change one line in `MODULE.bazel` |
| Correctness | Fine | **Unsafe**: schema types and operations from different versions do not compile together, and an app links exactly one `ApolloAPI` | Operations inherit the schema's version; mismatches fail analysis |
| Gradual migration | Two rulesets side by side | Too granular to be useful | `apollo_schema(cli = "@apollo_next//:cli")` pins one schema (one app) at a time |
| Maintenance | N copies of the rules, N CI matrices | One | One. The fork's CLI interface (`--bazel-*` flags, worker) is identical across all 34 releases, so the only per-version logic is a table of version-gated options |
| Workers | Separate | Worker pools multiply | One pool per (schema, CLI binary) |
| Remote execution | Fine | Fine | Toolchain resolution picks the right binary per exec platform (macOS locally, Linux on RBE) |

What actually constrains versioning is the runtime. Generated code must match the `ApolloAPI` it compiles
against, and an app binary links one `ApolloAPI`. So in practice the version moves per app. In a monorepo with
several apps, each app's schema can move separately with the `cli` override.

Within one app, runtimes go further: two Apollo iOS versions linked side by side, with each module on
one of them, so a large app can migrate module by module. See [MIGRATIONS.md](MIGRATIONS.md).

## Discovery: splitting the schema module

### What actually invalidates what (measured)

Measured with `examples/animal_kingdom` on Bazel 9.2, with each change applied to the built app:

| Change | Codegen actions (worker, ms) | Swift recompiles |
|---|---|---|
| Edit one feature's query | schema types + that feature | **That feature only.** Schema types output is byte-identical, so early cutoff applies |
| Add a field to a type (unused) | all | **None** |
| Edit a type description (`schemaDocumentation: include`) | all | Schema module only. Docs land in `.swiftdoc`, so dependents are cut off |
| Add an enum case / a type implementing an interface | all | **Schema module + every feature module**, including modules whose generated code did not change |

So the pain is not "any schema change". It is narrower: any change to the schema module's Swift interface
recompiles every dependent. Schema types hold no fields; fields live in each feature's generated selection
sets. The trigger is therefore type-level changes: new or removed types, enum cases, input object fields,
interface or union membership. Field additions don't trigger it.

If your current pipeline regenerates and checks in all generated code from a script, every schema sync
touches everything. Moving codegen into Bazel actions (this repo) already removes most of that.

### Options

1. **Keep one schema module (today).** Plus cheap mitigations:
   * `schemaDocumentation: exclude` keeps doc-only edits out of the build entirely.
   * Batch schema syncs (e.g. daily) rather than per backend deploy.
   * Remote cache, so a schema bump is paid once per CI fleet, not per engineer.

2. **Multiple schemas/subgraphs, one module each.** This works with these rules today: one
   `apollo_schema` per schema. Use it only for truly independent domains. Costs:
   * Separate `ApolloClient`s and normalized caches, so entities shared between domains are not shared.
   * Shared types (e.g. `User`) are duplicated as distinct Swift types.
   * A query can't span domains.
   * Federation clients normally want the supergraph.

   Not recommended for one product backed by one supergraph.

3. **Shard the schema module (recommended direction, needs fork work).** Split the generated schema into:
   * `MyAPICore`: `SchemaMetadata`, the `SelectionSet` protocols, the namespace enums (`Objects`,
     `Interfaces`, `Unions`, `Enums`, `InputObjects`), interfaces and unions. Small and rarely changing.
   * `MyAPI_<shard>`: modules holding `public extension Objects { static let Dog = … }`, enums and input
     objects, grouped by domain or by hash. Cross-module extensions of the namespace enums work in Swift.
     Generated operations already spell types as `MyAPI.Objects.Dog`, which still resolves when the shard
     is imported.
   * `SchemaMetadata.objectType(forTypename:)`: today a static switch over every object, so it depends on
     everything. It becomes a registry filled by a tiny app-level module that depends on all shards.

   Each feature then depends only on the shards it references. A new enum case recompiles one shard and its
   users. Costs:
   * A codegen change in the fork (new templates and a `--bazel-mode schema_shard`).
   * Feature `deps` must list shards. They're static in BUILD files, so this needs a Gazelle extension or
     an `apollo_deps` fix-up tool (the CLI already knows each operation's referenced types).
   * Registry bootstrapping in tests.

   Per-type modules would be too many Swift modules. Group them.

Suggested path: (1) now. Gather data on how often type-level schema changes land and how many modules they
rebuild (the BEP gives this directly). Then invest in (3) if it's a top build-time cost. Avoid (2) unless the
domains are already separate products.

## CLI issues (fork)

### Resolved (fork releases of 2026-10-04)

Found while building these rules. The fork fixed them on every `<ver>-rust-parity` branch, and the rules
now rely on the fixes. Every version in `versions.bzl` has them; a custom CLI registered with
`apollo_toolchain` must be built from those branches.

| Issue | Fork fix | Rules change |
|---|---|---|
| Discovery ignored file-symlink inputs | Follows links; literal paths are checked directly | Dropped `no-sandbox`. Verified with `--strategy=ApolloCodegen=sandboxed` and `--worker_sandboxing` |
| `V4` hardcodes in Bazel mode | Removed; the metadata optimizer uses the configured namespace | None needed |
| Bazel mode deleted `SchemaConfiguration.swift` and `CustomScalars/` | `--bazel-keep-schema-configuration` | The CLI's files are used. `schema_configuration` replaces the generated file, and `custom_scalars` lists the scalars you implement yourself (their String typealias is dropped) |
| Generation selected by path prefix | `--bazel-generate-for <file>`, repeatable | Exact selection. The nested/same-suffix package restriction is gone |
| `--version` was `2.1.0-rc-1` everywhere | Reports the branch's version | None needed |
| No test mocks in Bazel mode | `--bazel-mode test_mocks` plus scoping flags | `apollo_test_mocks` ([MOCKS.md](MOCKS.md)) |
| Singleplex worker | Multiplex, with a shared schema cache | Actions declare `supports-multiplex-workers` |
| Compilation cache keyed only on operations | Keyed on config + schema + operation digests | None needed |
| Invalid operations panicked and killed the worker | Validation errors; the worker keeps serving | None needed |
| Draft releases | All 34 published | `versions.bzl` lists all 34. The fork-only 1.15.4 is skipped (no upstream runtime) |
| Mocks had no fields in Bazel mode (empty `MockFields` under `--bazel-output-dir`, both modes) | The CLI builds the IR of every compiled operation and fragment before generating mocks; Bazel-mode mocks are verified byte-identical to plain `generate` and to the Swift CLI on all 34 versions ([MOCKS.md §2.5](MOCKS.md)) | None needed; the example's mock tests can use fields. A mocks action must still compile every operation |
| One-shot Bazel mode pruned `*.graphql.swift` files under the *configured* output paths (relative to the execroot) | Pruning is off under `--bazel-output-dir` (the worker already had it off) | None needed |

There is still no `x86_64-apple-darwin` build, by decision.

### Open

None at the moment.

## Roadmap: what a large modular app wants next

Ordered by expected payoff for a big modular iOS app:

1. **Schema sharding** (above), if measurements show type-level schema changes are a top build cost. Feature
   deps on shards would need tooling to stay current.
2. **`apollo_validate_test`.** Validate every operation against a candidate schema without generating Swift.
   Run it in the backend's CI on schema PRs to catch client breakage before the schema ships.
3. **Schema change impact report.** Compare the generated outputs for two schema revisions and list the
   affected modules and owners. Post it on schema-sync PRs.
4. **Persisted queries end to end.** The manifest is already an output group. Add an upload/publish
   `bazel run` target and a test that fails when an operation's ID is missing from the safelist.
5. ~~**Test mocks per feature.**~~ Done: `apollo_test_mocks`, the partition test and the updater
   ([MOCKS.md](MOCKS.md)). Mock fields in Bazel mode are fixed in the fork's second mocks release.
6. **Deprecation tracking.** Use `warningsOnDeprecatedUsage` output aggregated per module, so field
   deprecations can be routed to code owners and burned down.
7. ~~**Multiplex worker, sandbox-safe CLI, no panics.**~~ Done in the fork and the rules. Dynamic
   execution (`--strategy=ApolloCodegen=dynamic`) is not yet tested.
8. **Schema fetch** as a repository rule or `bazel run` target (registry or introspection, with credentials
   from the environment), so the schema snapshot has one owner and cadence.
9. ~~**rules_xcodeproj check.**~~ Done in `examples/rick_and_morty`. The generated project contains every
   shard, builds and tests through `xcodebuild`, and the Bazel index stores carry units for every
   generated file. Jump to definition in the Xcode UI is the only part not checked automatically.
