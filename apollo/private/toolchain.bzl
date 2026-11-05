"""The apollo-ios-cli toolchain."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(":providers.bzl", "ApolloCliInfo")

APOLLO_TOOLCHAIN_TYPE = Label("//apollo:toolchain_type")
CODEGEN_EXEC_TOOLCHAIN_TYPE = Label("//apollo:codegen_exec_toolchain_type")

# Toolchains of every rule that runs the CLI. The codegen_exec one is mandatory: it
# is what pins those targets to the host with --@rules_apollo//apollo:codegen_exec=local.
CODEGEN_TOOLCHAINS = [
    config_common.toolchain_type(APOLLO_TOOLCHAIN_TYPE, mandatory = False),
    CODEGEN_EXEC_TOOLCHAIN_TYPE,
]

# Lets codegen rules read --@rules_apollo//apollo:codegen_exec.
CODEGEN_EXEC_ATTRS = {
    "_codegen_exec": attr.label(default = Label("//apollo:codegen_exec")),
}

def _codegen_exec_toolchain_impl(_ctx):
    return [platform_common.ToolchainInfo()]

codegen_exec_toolchain = rule(
    implementation = _codegen_exec_toolchain_impl,
    doc = "Placeholder implementation of the codegen_exec toolchain type; only its constraints matter.",
)

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

def codegen_runs_locally(ctx):
    """Whether --@rules_apollo//apollo:codegen_exec=local is set.

    Args:
        ctx: context of a rule with CODEGEN_EXEC_ATTRS.

    Returns:
        bool
    """
    return ctx.attr._codegen_exec[BuildSettingInfo].value == "local"

def codegen_exec_requirements(ctx):
    """Execution requirements that keep codegen off remote execution in local mode.

    Results are still uploaded to and read from the remote cache.

    Args:
        ctx: context of a rule with CODEGEN_EXEC_ATTRS.

    Returns:
        dict
    """
    return {"no-remote-exec": "1"} if codegen_runs_locally(ctx) else {}
