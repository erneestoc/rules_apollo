"""Module extension that provides apollo-ios-cli toolchains.

    apollo = use_extension("@rules_apollo//apollo:extensions.bzl", "apollo")
    apollo.toolchain(version = "2.4.0")

The root module's default toolchain wins; rules_apollo registers a default so the
extension works with no configuration. Extra named toolchains are not registered;
use them per schema through `apollo_schema(cli = "@<name>//:cli")`, which is how a
large repo migrates one schema at a time.

Runtimes let one app use two Apollo iOS versions while it migrates, one module at a
time (docs/MIGRATIONS.md):

    apollo.runtime(name = "current", version = "1.15.2")
    apollo.runtime(name = "next", version = "2.4.0", module_suffix = "_v2")
"""

load("//apollo/private:repositories.bzl", "DEFAULT_URL_TEMPLATE", "PLATFORMS", "apollo_cli_repo", "apollo_toolchains_hub", "sha256s_for")
load("//apollo/private:runtime_repositories.bzl", "apollo_runtime_repo", "apollo_runtimes_hub")
load("//apollo/private:versions.bzl", "APOLLO_CLI_REPO", "APOLLO_IOS_SOURCE_SHA256")

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

_runtime = tag_class(
    doc = "Declares an Apollo iOS runtime: a CLI plus the Apollo iOS libraries of one version.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Referenced by the macros' `runtime`/`runtimes`."),
        "version": attr.string(mandatory = True, doc = "Apollo iOS version, e.g. \"1.15.2\"."),
        "module_suffix": attr.string(
            doc = "Appended to every module of this runtime (`ApolloAPI_v2`, `MyAPI_v2`, …) so it can " +
                  "be linked next to another runtime. Leave empty for exactly one runtime.",
        ),
        "sha256": attr.string(doc = "sha256 of the apollo-ios source archive, for versions not in the table."),
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

def _cli_repos(version, sha256s, repo, url_templates, created):
    """Declares the per-platform CLI repos of a version once; returns triple -> repo name."""
    cli_repos = {}
    for triple, sha256 in sha256s_for(version, sha256s).items():
        if triple not in PLATFORMS:
            continue
        name = _repo_name(version, triple)
        if name not in created:
            apollo_cli_repo(
                name = name,
                version = version,
                triple = triple,
                sha256 = sha256,
                repo = repo,
                url_templates = url_templates,
            )
            created[name] = True
        cli_repos[triple] = name
    return cli_repos

def _apollo_impl(mctx):
    # name -> tag. Root module first, so its choices win over dependencies'.
    selected = {}
    runtimes = {}
    for mod in mctx.modules:
        for tag in mod.tags.toolchain:
            if tag.name not in selected:
                selected[tag.name] = tag
        for tag in mod.tags.runtime:
            if tag.name not in runtimes:
                runtimes[tag.name] = tag

    created = {}
    for name, tag in selected.items():
        cli_repos = _cli_repos(tag.version, tag.sha256s, tag.repo, tag.url_templates, created)
        if name == _DEFAULT_NAME:
            apollo_toolchains_hub(name = name, cli_repos = cli_repos)
        else:
            _cli_alias_repo(name = name, cli_repos = cli_repos)

    suffixes = {}
    for name, tag in runtimes.items():
        if tag.module_suffix in suffixes:
            fail("apollo.runtime %r and %r both use module_suffix %r; each runtime needs its own." %
                 (suffixes[tag.module_suffix], name, tag.module_suffix))
        suffixes[tag.module_suffix] = name
        sha256 = tag.sha256 or APOLLO_IOS_SOURCE_SHA256.get(tag.version)
        if not sha256:
            fail("apollo.runtime %r: no known sha256 for apollo-ios %s; pass `sha256`." % (name, tag.version))
        _cli_alias_repo(
            name = "apollo_runtime_%s_cli" % name,
            cli_repos = _cli_repos(tag.version, {}, APOLLO_CLI_REPO, [DEFAULT_URL_TEMPLATE], created),
        )
        apollo_runtime_repo(
            name = "apollo_runtime_" + name,
            version = tag.version,
            suffix = tag.module_suffix,
            sha256 = sha256,
        )

    # Always created, so the macros can load it; empty when no runtimes are declared.
    apollo_runtimes_hub(
        name = "apollo_runtimes",
        runtimes = {name: "%s|%s" % (tag.version, tag.module_suffix) for name, tag in runtimes.items()},
    )

    return mctx.extension_metadata(reproducible = True)

apollo = module_extension(
    implementation = _apollo_impl,
    tag_classes = {"toolchain": _toolchain, "runtime": _runtime},
)
