"""apollo_schema: generates the shared schema-types module."""

load(":config.bzl", "build_base_config", "codegen_config")
load(":providers.bzl", "ApolloCliInfo", "ApolloSchemaInfo")
load(":sources.bzl", "generated_swift_sources")
load(":toolchain.bzl", "APOLLO_TOOLCHAIN_TYPE", "resolve_cli")
load(":worker.bzl", "codegen_args", "codegen_execution_requirements", "worker_env")

def _apollo_schema_impl(ctx):
    cli = resolve_cli(ctx)
    base_config = build_base_config(ctx, cli.version)
    namespace = base_config["schemaNamespace"]

    schema_files = ctx.files.schema
    operation_files = ctx.files.srcs

    # Schema types. Apollo only emits types referenced by some operation, which is
    # why this target sees every .graphql file in the app. The CLI also writes its
    # default SchemaConfiguration.swift and one String typealias per custom scalar;
    # the ones the user implements are left out.
    schema_types = ctx.actions.declare_directory(ctx.label.name + "_schema_types")
    args = codegen_args(
        ctx,
        config = codegen_config(base_config, schema_files, operation_files),
        output_dir = schema_types,
        mode = "schema_types",
        extra = ["--bazel-keep-schema-configuration"],
    )
    ctx.actions.run(
        executable = cli.cli,
        arguments = [args],
        inputs = depset(schema_files + operation_files),
        outputs = [schema_types],
        mnemonic = "ApolloCodegen",
        progress_message = "Generating Apollo schema types %{label}",
        execution_requirements = codegen_execution_requirements(),
        env = worker_env(ctx.label),
        toolchain = None if ctx.attr.cli else APOLLO_TOOLCHAIN_TYPE,
    )

    replaced = ["CustomScalars/%s.swift" % name for name in ctx.attr.custom_scalars]
    if ctx.file.schema_configuration:
        replaced.append("SchemaConfiguration.swift")
    outputs = [generated_swift_sources(ctx, schema_types, exclude = replaced)]
    if ctx.file.schema_configuration:
        outputs.append(ctx.file.schema_configuration)

    output_groups = {"generated_tree": depset([schema_types])}

    # 3. Persisted-queries manifest for the whole app.
    if ctx.attr.operation_manifest_version:
        manifest = ctx.actions.declare_file(ctx.label.name + "_operation_manifest.json")
        manifest_config = json.decode(codegen_config(base_config, schema_files, operation_files))
        manifest_config["operationManifest"] = {
            "path": manifest.path,
            "version": ctx.attr.operation_manifest_version,
        }
        manifest_args = ctx.actions.args()
        manifest_args.add("generate-operation-manifest")
        manifest_args.add("--string", json.encode(manifest_config))
        manifest_args.use_param_file("@%s", use_always = True)
        manifest_args.set_param_file_format("multiline")
        ctx.actions.run(
            executable = cli.cli,
            arguments = [manifest_args],
            inputs = depset(schema_files + operation_files),
            outputs = [manifest],
            mnemonic = "ApolloOperationManifest",
            progress_message = "Generating Apollo operation manifest %{label}",
            toolchain = None if ctx.attr.cli else APOLLO_TOOLCHAIN_TYPE,
        )
        output_groups["operation_manifest"] = depset([manifest])

    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(**output_groups),
        ApolloSchemaInfo(
            label = ctx.label,
            namespace = namespace,
            schema_files = depset(schema_files),
            operation_files = depset(operation_files),
            config = base_config,
            version = cli.version,
            cli_override = cli if ctx.attr.cli else None,
        ),
    ]

apollo_schema = rule(
    implementation = _apollo_schema_impl,
    doc = """Generates the schema-types Swift module for a GraphQL schema.

The default output is a directory of generated Swift files (plus
`schema_configuration`, if set) meant for a `swift_library` whose `module_name` equals `schema_namespace`. Operation modules are
generated separately by `apollo_operations` targets that point at this one.

`srcs` must contain every .graphql file of the app: Apollo generates only the schema
types that some operation references. Bazel's content-based early cutoff means an
operation change that does not change the set of referenced types leaves the outputs
byte-identical, so nothing downstream recompiles.""",
    attrs = {
        "schema": attr.label_list(
            mandatory = True,
            allow_files = [".graphqls", ".graphql", ".json"],
            doc = "Schema files: SDL (.graphqls) or introspection JSON.",
        ),
        "srcs": attr.label_list(
            mandatory = True,
            allow_empty = False,
            allow_files = [".graphql"],
            doc = "Every operation and fragment of the app. The CLI rejects a schema with no operations.",
        ),
        "schema_namespace": attr.string(
            doc = "schemaNamespace, which is also the Swift module name of the schema types. Defaults to the target name.",
        ),
        "options": attr.string(
            doc = "JSON object with apollo-codegen-config.json `options` (same keys as Apollo's docs).",
        ),
        "experimental_features": attr.string(
            doc = "JSON object with apollo-codegen-config.json `experimentalFeatures`.",
        ),
        "schema_configuration": attr.label(
            allow_single_file = [".swift"],
            doc = "Your SchemaConfiguration.swift, replacing the generated default (no cache keys).",
        ),
        "custom_scalars": attr.string_list(
            doc = "Custom scalars you implement yourself (in the Swift module's other sources). " +
                  "The CLI's default `typealias <Name> = String` for each is left out.",
        ),
        "operation_manifest_version": attr.string(
            values = ["", "persistedQueries", "legacy"],
            doc = "If set, also produces an operation manifest in the `operation_manifest` output group.",
        ),
        "cli": attr.label(
            providers = [ApolloCliInfo],
            cfg = "exec",
            doc = "Overrides the registered toolchain, e.g. to migrate one schema to a new Apollo version.",
        ),
    },
    provides = [ApolloSchemaInfo],
    toolchains = [config_common.toolchain_type(APOLLO_TOOLCHAIN_TYPE, mandatory = False)],
)
