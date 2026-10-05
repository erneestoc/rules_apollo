"""Repository rules for prebuilt apollo-ios-cli binaries."""

load(":versions.bzl", "APOLLO_CLI_REPO", "APOLLO_CLI_VERSIONS")

DEFAULT_URL_TEMPLATE = "https://github.com/{repo}/releases/download/{version}/apollo-ios-cli-{triple}.tar.gz"

# Rust target triple -> exec_compatible_with constraints.
PLATFORMS = {
    "aarch64-apple-darwin": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "aarch64-unknown-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "x86_64-unknown-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
}

def _apollo_cli_repo_impl(rctx):
    urls = [
        t.format(repo = rctx.attr.repo, version = rctx.attr.version, triple = rctx.attr.triple)
        for t in rctx.attr.url_templates
    ]
    rctx.download_and_extract(url = urls, sha256 = rctx.attr.sha256)
    rctx.file("BUILD.bazel", """\
load("@rules_apollo//apollo:defs.bzl", "apollo_toolchain")

apollo_toolchain(
    name = "toolchain_impl",
    cli = "apollo-ios-cli",
    version = "{version}",
    visibility = ["//visibility:public"],
)
""".format(version = rctx.attr.version))

apollo_cli_repo = repository_rule(
    implementation = _apollo_cli_repo_impl,
    doc = "Downloads one prebuilt apollo-ios-cli release binary.",
    attrs = {
        "version": attr.string(mandatory = True),
        "triple": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "repo": attr.string(default = APOLLO_CLI_REPO),
        "url_templates": attr.string_list(default = [DEFAULT_URL_TEMPLATE]),
    },
)

def _apollo_toolchains_hub_impl(rctx):
    content = []
    for triple, repo in rctx.attr.cli_repos.items():
        content.append("""\
toolchain(
    name = "{triple}",
    exec_compatible_with = {constraints},
    toolchain = "@{repo}//:toolchain_impl",
    toolchain_type = "@rules_apollo//apollo:toolchain_type",
)
""".format(triple = triple, constraints = repr(PLATFORMS[triple]), repo = repo))
    rctx.file("BUILD.bazel", "\n".join(content))

apollo_toolchains_hub = repository_rule(
    implementation = _apollo_toolchains_hub_impl,
    doc = "Declares one toolchain() per platform. The CLI repos are only fetched if selected.",
    attrs = {
        "cli_repos": attr.string_dict(doc = "triple -> repo name"),
    },
)

def sha256s_for(version, overrides):
    """Returns {triple: sha256} for a version from the known table plus overrides.

    Args:
        version: Apollo iOS version.
        overrides: triple -> sha256 from the toolchain tag.

    Returns:
        dict
    """
    sha256s = dict(APOLLO_CLI_VERSIONS.get(version, {}))
    sha256s.update(overrides)
    if not sha256s:
        fail(("Unknown apollo-ios-cli version %r. Known: %s. For other builds pass `sha256s` " +
              "to apollo.toolchain().") % (version, ", ".join(APOLLO_CLI_VERSIONS.keys())))
    return sha256s
