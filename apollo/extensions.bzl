"""Module extension that provides apollo-ios-cli toolchains.

    apollo = use_extension("@rules_apollo//apollo:extensions.bzl", "apollo")
    apollo.toolchain(version = "2.4.0")

The root module's default toolchain wins; rules_apollo registers a default so the
extension works with no configuration. Extra named toolchains are not registered;
use them per schema through `apollo_schema(cli = "@<name>//:cli")`, which is how a
large repo migrates one schema at a time.
"""

load("//apollo/private:repositories.bzl", "DEFAULT_URL_TEMPLATE", "PLATFORMS", "apollo_cli_repo", "apollo_toolchains_hub", "sha256s_for")
load("//apollo/private:versions.bzl", "APOLLO_CLI_REPO")

_DEFAULT_NAME = "apollo_toolchains"

_toolchain = tag_class(
    doc = "Declares an apollo-ios-cli version.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "Apollo iOS version, e.g. \"2.4.0\"."),
        "name": attr.string(
            default = _DEFAULT_NAME,
            doc = "Leave unset for the registered default. Any other name creates `@<name>//:cli` " +
                  "for per-schema use and must be brought into scope with use_repo().",
        ),
        "sha256s": attr.string_dict(
            doc = "triple -> sha256 for versions or builds not in the built-in table.",
        ),
        "repo": attr.string(
            default = APOLLO_CLI_REPO,
            doc = "GitHub owner/repo that publishes the release archives.",
        ),
        "url_templates": attr.string_list(
            default = [DEFAULT_URL_TEMPLATE],
            doc = "Mirrors to try in order. Placeholders: {repo}, {version}, {triple}.",
        ),
    },
)

def _cli_alias_repo_impl(rctx):
    # select() on the exec platform so `cli = "@name//:cli"` (cfg = "exec") works locally and on RBE.
    rctx.file("BUILD.bazel", """\
alias(
    name = "cli",
    actual = select({select}),
    visibility = ["//visibility:public"],
)
""".format(select = repr({
        "@rules_apollo//apollo/private:" + triple: "@%s//:toolchain_impl" % repo
        for triple, repo in rctx.attr.cli_repos.items()
    })))

_cli_alias_repo = repository_rule(
    implementation = _cli_alias_repo_impl,
    attrs = {"cli_repos": attr.string_dict()},
)

def _repo_name(version, triple):
    return "apollo_cli_%s_%s" % (version.replace(".", "_"), triple)

def _apollo_impl(mctx):
    # name -> tag. Root module first, so its choices win over dependencies'.
    selected = {}
    for mod in mctx.modules:
        for tag in mod.tags.toolchain:
            if tag.name not in selected:
                selected[tag.name] = tag

    created = {}
    for name, tag in selected.items():
        cli_repos = {}
        for triple, sha256 in sha256s_for(tag.version, tag.sha256s).items():
            if triple not in PLATFORMS:
                continue
            repo = _repo_name(tag.version, triple)
            if repo not in created:
                apollo_cli_repo(
                    name = repo,
                    version = tag.version,
                    triple = triple,
                    sha256 = sha256,
                    repo = tag.repo,
                    url_templates = tag.url_templates,
                )
                created[repo] = True
            cli_repos[triple] = repo

        if name == _DEFAULT_NAME:
            apollo_toolchains_hub(name = name, cli_repos = cli_repos)
        else:
            _cli_alias_repo(name = name, cli_repos = cli_repos)

    return mctx.extension_metadata(reproducible = True)

apollo = module_extension(
    implementation = _apollo_impl,
    tag_classes = {"toolchain": _toolchain},
)
