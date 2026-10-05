"""The apollo-ios-cli toolchain."""

load(":providers.bzl", "ApolloCliInfo")

APOLLO_TOOLCHAIN_TYPE = Label("//apollo:toolchain_type")

def _apollo_toolchain_impl(ctx):
    cli = ApolloCliInfo(
        cli = ctx.attr.cli[DefaultInfo].files_to_run,
        version = ctx.attr.version,
    )
    return [
        platform_common.ToolchainInfo(apollo = cli),
        cli,
    ]

apollo_toolchain = rule(
    implementation = _apollo_toolchain_impl,
    doc = """Declares an apollo-ios-cli binary for a given Apollo iOS version.

Use this directly (plus `toolchain()` and `register_toolchains()`) to run a CLI you
build yourself, e.g. from source with rules_rust. The `apollo` module extension
declares these for the prebuilt release binaries.""",
    attrs = {
        "cli": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            allow_files = True,
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Apollo iOS version the CLI generates code for. Controls version-gated options.",
        ),
    },
    provides = [ApolloCliInfo],
)

def resolve_cli(ctx):
    """Returns the ApolloCliInfo from the `cli` attr if set, else from the toolchain.

    Args:
        ctx: rule context with an optional `cli` attr and the apollo toolchain.

    Returns:
        ApolloCliInfo
    """
    if getattr(ctx.attr, "cli", None):
        return ctx.attr.cli[ApolloCliInfo]
    toolchain = ctx.toolchains[APOLLO_TOOLCHAIN_TYPE]
    if not toolchain:
        fail("No apollo-ios-cli toolchain is registered for this execution platform. " +
             "Prebuilt binaries exist for aarch64-apple-darwin, aarch64-linux and x86_64-linux.")
    return toolchain.apollo

def resolve_cli_for_schema(ctx, schema):
    """Returns the CLI for a target generated against `schema`.

    Resolves the CLI for this target's own exec platform, but pins it to the
    schema's version: schema types, operations and mocks must come from one release.

    Args:
        ctx: rule context with the apollo toolchain.
        schema: ApolloSchemaInfo.

    Returns:
        ApolloCliInfo
    """
    if schema.cli_override:
        return schema.cli_override
    cli = resolve_cli(ctx)
    if cli.version != schema.version:
        fail("%s: the apollo toolchain is %s but schema %s was generated with %s." %
             (ctx.label, cli.version, schema.label, schema.version))
    return cli
