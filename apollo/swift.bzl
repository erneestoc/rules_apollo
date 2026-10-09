"""Macros that pair Apollo codegen with rules_swift `swift_library` targets.

    apollo_swift_schema(
        name = "MyAPI",
        schema = ["schema.graphqls"],
        srcs = ["//:all_graphql"],
        apollo_api = "@apollo_ios//:ApolloAPI",
    )

    apollo_swift_operations(
        name = "AccountGraphQL",
        schema = "//graphql:MyAPI",
        srcs = glob(["*.graphql"]),
        deps = ["//Features/Shared:SharedGraphQL"],   # for its fragments
        apollo_api = "@apollo_ios//:ApolloAPI",
    )

Each macro creates `<name>` (the swift_library) and `<name>_apollo` (codegen).

Runtimes (docs/MIGRATIONS.md): when MODULE.bazel declares `apollo.runtime(...)`s, the
schema, operations and mocks macros create one variant per runtime: `<name>` on the
target's home runtime (`runtime`, by default the one without a module suffix) and
`<name><suffix>` elsewhere, each also reachable as `<name>.<runtime>`. The Apollo iOS
libraries come from the runtime, so `apollo_api` / `apollo_test_support` are not needed.
Bazel only builds the variants something depends on. Your own code picks a runtime with
`apollo_swift_library(runtime = ...)`. Only Apollo iOS is aliased; other modules are
imported by their real names (`import CharactersGraphQL_v2`).
"""

load("@apollo_runtimes//:defs.bzl", "RUNTIMES")
load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")
load("//apollo:defs.bzl", "apollo_mock_partition_test", "apollo_mock_partition_update", "apollo_operations", "apollo_schema", "apollo_test_mocks")
load("//apollo/private:runtime_repositories.bzl", "runtime_aliases", "runtime_defines")

_CODEGEN_SUFFIX = "_apollo"

def _label(label, suffix = "", codegen = False):
    label = native.package_relative_label(label)
    return label.same_package_label(label.name + suffix + (_CODEGEN_SUFFIX if codegen else ""))

def _on(label, rt, codegen = False):
    """The variant of a runtime-aware target on `rt`, via its `<name>.<runtime>` alias."""
    return _label(label, "." + rt.name if rt else "", codegen)

def _encode(value):
    return json.encode(value) if value else None

def _runtime(name):
    if name not in RUNTIMES:
        fail("Unknown Apollo runtime %r. Declared with apollo.runtime(): %s" %
             (name, ", ".join(sorted(RUNTIMES)) or "none"))
    return RUNTIMES[name]

def _default_home():
    for name in sorted(RUNTIMES):
        if not RUNTIMES[name].suffix:
            return name
    return sorted(RUNTIMES)[0]

def _variants(home, runtimes = None):
    """[(runtime, name suffix)] for a runtime-aware target; [(None, "")] without runtimes.

    The target keeps its plain name on its home runtime. Variants on other runtimes
    get the runtime's module suffix (or `_<runtime>` when it has none).
    """
    if not RUNTIMES:
        return [(None, "")]
    home = home or _default_home()
    _runtime(home)
    names = runtimes if runtimes != None else sorted(RUNTIMES)
    if home not in names:
        fail("Home runtime %r must be one of the variants %s." % (home, names))
    variants = []
    for name in names:
        rt = _runtime(name)
        variants.append((rt, "" if name == home else (rt.suffix or "_" + name)))
    return variants

def _alias_variant(name, rt, suffix, visibility, tags, codegen = True):
    """Declares `<name>.<runtime>` (and its codegen alias) pointing at the variant."""
    if not rt:
        return
    native.alias(name = name + "." + rt.name, actual = name + suffix, visibility = visibility, tags = tags)
    if codegen:
        native.alias(
            name = name + "." + rt.name + _CODEGEN_SUFFIX,
            actual = name + suffix + _CODEGEN_SUFFIX,
            visibility = visibility,
            tags = tags,
        )

def _copts(rt):
    """Swift flags for a target on runtime `rt`: Apollo iOS module aliases and the version define.

    Only Apollo iOS is aliased (`import ApolloAPI` reaches `ApolloAPI_v2`); every other
    module is referenced by its real name, e.g. `import CharactersGraphQL_v2`.
    """
    if not rt:
        return []
    return runtime_aliases(rt.suffix) + runtime_defines(rt.version)

def _require(value, what, rt):
    if not rt and not value:
        fail("`%s` is required when no apollo.runtime() is declared." % what)
    return value

def apollo_runtime(name):
    """Looks up a declared runtime, for BUILD files that use the rules directly.

    Args:
        name: name of an apollo.runtime().

    Returns:
        struct with `name`, `version`, `suffix`, and labels `cli`, `apollo_api`, `apollo`,
        `apollo_test_support`.
    """
    return _runtime(name)

# buildifier: disable=unnamed-macro
def apollo_runtime_copts(runtime):
    """Swift copts for a target of your own on `runtime`, for rules other than apollo_swift_library.

    Args:
        runtime: name of an apollo.runtime().

    Returns:
        list of copts: Apollo iOS module aliases and `-DAPOLLO_IOS_<major>`.
    """
    return _copts(_runtime(runtime))

def apollo_swift_schema(
        name,
        schema,
        apollo_api = None,
        srcs = [],
        schema_namespace = None,
        options = {},
        experimental_features = {},
        custom_scalars = [],
        schema_configuration = None,
        operation_manifest_version = None,
        cli = None,
        runtime = None,
        runtimes = None,
        swift_srcs = [],
        deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates schema types and compiles them into a Swift module named `schema_namespace`.

    With runtimes, one variant per runtime. Off its home runtime, the variant's module and
    its generated namespace are both `<schema_namespace><suffix>` (e.g. `MyAPI_v2`), so code
    refers to it by its real name.

    Args:
        name: swift_library name. `schema_namespace` defaults to it.
        schema: schema files (.graphqls or introspection .json).
        apollo_api: label of the ApolloAPI swift_library. Not used with runtimes.
        srcs: every .graphql file of the app.
        schema_namespace: Swift module name and Apollo schemaNamespace.
        options: dict with apollo-codegen-config.json `options`.
        experimental_features: dict with `experimentalFeatures`.
        custom_scalars: custom scalars you implement in `swift_srcs` (drops the generated String typealias).
        schema_configuration: your SchemaConfiguration.swift.
        operation_manifest_version: "persistedQueries" or "legacy" to emit a manifest.
        cli: per-schema CLI override, e.g. "@apollo_next//:cli". Not used with runtimes.
        runtime: home runtime (plain names). Defaults to the runtime without a module suffix.
        runtimes: runtimes to create variants for. Defaults to every declared runtime.
        swift_srcs: extra Swift sources for the module (custom scalars, extensions).
        deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    namespace = schema_namespace or name
    copts = kwargs.pop("copts", [])
    for rt, suffix in _variants(runtime, runtimes):
        apollo_schema(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = schema,
            srcs = srcs,
            schema_namespace = namespace + suffix,
            options = _encode(options),
            experimental_features = _encode(experimental_features),
            custom_scalars = custom_scalars,
            schema_configuration = schema_configuration,
            operation_manifest_version = operation_manifest_version,
            cli = rt.cli if rt else cli,
            visibility = visibility,
            tags = tags,
        )
        swift_library(
            name = name + suffix,
            module_name = namespace + suffix,
            srcs = [name + suffix + _CODEGEN_SUFFIX] + swift_srcs,
            deps = [rt.apollo_api if rt else _require(apollo_api, "apollo_api", rt)] + deps,
            copts = _copts(rt) + copts,
            visibility = visibility,
            tags = tags,
            **kwargs
        )
        _alias_variant(name, rt, suffix, visibility, tags)

def apollo_swift_operations(
        name,
        schema,
        apollo_api = None,
        srcs = [],
        deps = [],
        module_name = None,
        access_modifier = "public",
        runtime = None,
        runtimes = None,
        swift_srcs = [],
        swift_deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates one framework's operations and compiles them into a Swift module.

    With runtimes, one variant per runtime: `<name>` on its home runtime, `<name><suffix>`
    elsewhere (e.g. `CharactersGraphQL_v2`, for features on another runtime that spread its
    fragments). Bazel only builds the variants something uses.

    Args:
        name: swift_library name. `module_name` defaults to it.
        schema: an apollo_swift_schema target.
        apollo_api: label of the ApolloAPI swift_library. Not used with runtimes.
        srcs: .graphql files owned by this module.
        deps: other apollo_swift_operations whose fragments these operations use.
        module_name: Swift module name.
        access_modifier: "public" or "internal".
        runtime: home runtime (plain names). Defaults to the runtime without a module suffix.
        runtimes: runtimes to create variants for. Defaults to every declared runtime.
        swift_srcs: extra Swift sources for the module.
        swift_deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    module = module_name or name
    copts = kwargs.pop("copts", [])
    for rt, suffix in _variants(runtime, runtimes):
        apollo_operations(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = _on(schema, rt, codegen = True),
            srcs = srcs,
            deps = [_on(d, rt, codegen = True) for d in deps],
            module_name = module + suffix,
            access_modifier = access_modifier,
            visibility = visibility,
            tags = tags,
        )
        swift_library(
            name = name + suffix,
            module_name = module + suffix,
            srcs = [name + suffix + _CODEGEN_SUFFIX] + swift_srcs,
            deps = [_on(schema, rt), rt.apollo_api if rt else _require(apollo_api, "apollo_api", rt)] +
                   [_on(d, rt) for d in deps] + swift_deps,
            copts = _copts(rt) + copts,
            visibility = visibility,
            tags = tags,
            **kwargs
        )
        _alias_variant(name, rt, suffix, visibility, tags)

def apollo_swift_test_mocks(
        name,
        schema,
        apollo_api = None,
        apollo_test_support = None,
        base = None,
        operations = [],
        srcs = [],
        types = [],
        exclude_types = [],
        module_name = None,
        access_modifier = "public",
        runtime = None,
        runtimes = None,
        swift_srcs = [],
        deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates one module of test mocks and compiles it into a testonly Swift module.

    Without `base` this is the base module (shared mocks and the MockObject typealiases);
    with `base` it holds the mocks exclusive to `operations`. See docs/MOCKS.md.

    Args:
        name: swift_library name. `module_name` defaults to it.
        schema: an apollo_swift_schema target.
        apollo_api: label of the ApolloAPI swift_library. Not used with runtimes.
        apollo_test_support: label of the ApolloTestSupport swift_library. Not used with runtimes.
        base: the base apollo_swift_test_mocks. Unset for the base itself.
        operations: features: apollo_swift_operations whose operations define the scope.
        srcs: features: extra .graphql files for the scope.
        types: base: owned types (maintained by the partition updater). Feature: extra types.
        exclude_types: base only: feature-owned types (maintained by the partition updater).
        module_name: Swift module name.
        access_modifier: "public" or "internal".
        runtime: home runtime (plain names). Defaults to the runtime without a module suffix.
        runtimes: runtimes to create variants for. Defaults to every declared runtime.
        swift_srcs: hand-written test helpers compiled into the same module.
        deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    module = module_name or name
    copts = kwargs.pop("copts", [])
    for rt, suffix in _variants(runtime, runtimes):
        apollo_test_mocks(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = _on(schema, rt, codegen = True),
            base = _on(base, rt, codegen = True) if base else None,
            operations = [_on(o, rt, codegen = True) for o in operations],
            srcs = srcs,
            types = types,
            exclude_types = exclude_types,
            module_name = module + suffix,
            access_modifier = access_modifier,
            build_target = name,
            testonly = True,
            visibility = visibility,
            tags = tags,
        )
        swift_library(
            name = name + suffix,
            module_name = module + suffix,
            srcs = [name + suffix + _CODEGEN_SUFFIX] + swift_srcs,
            deps = [
                _on(schema, rt),
                rt.apollo_api if rt else _require(apollo_api, "apollo_api", rt),
                rt.apollo_test_support if rt else _require(apollo_test_support, "apollo_test_support", rt),
            ] + ([_on(base, rt)] if base else []) + deps,
            copts = _copts(rt) + copts,
            testonly = True,
            visibility = visibility,
            tags = tags,
            **kwargs
        )
        _alias_variant(name, rt, suffix, visibility, tags)

def apollo_swift_mock_partition(name, base, feature_mocks, runtime = None, runtimes = None, visibility = None, tags = []):
    """Declares `<name>` (the partition test) and `<name>_update` (bazel run to fix it).

    With runtimes, one pair per runtime, named like the other variants.

    Args:
        name: test name.
        base: the base apollo_swift_test_mocks.
        feature_mocks: every feature apollo_swift_test_mocks with that base.
        runtime: home runtime (plain names). Defaults to the runtime without a module suffix.
        runtimes: runtimes to create variants for. Defaults to every declared runtime.
        visibility: visibility of the targets.
        tags: tags for the targets.
    """
    for rt, suffix in _variants(runtime, runtimes):
        common = dict(
            base = _on(base, rt, codegen = True),
            feature_mocks = [_on(f, rt, codegen = True) for f in feature_mocks],
            testonly = True,
            visibility = visibility,
            tags = tags,
        )
        apollo_mock_partition_test(name = name + suffix, **common)
        apollo_mock_partition_update(name = name + suffix + "_update", **common)

_APOLLO_DEPS = {
    "ApolloAPI": "apollo_api",
    "Apollo": "apollo",
    "ApolloTestSupport": "apollo_test_support",
}

def apollo_swift_library(
        name,
        runtime = None,
        runtimes = None,
        srcs = [],
        deps = [],
        runtime_deps = [],
        apollo_deps = ["ApolloAPI"],
        module_name = None,
        **kwargs):
    """A swift_library of your own that uses Apollo, on one runtime (or each of several).

    Code imports Apollo iOS as usual (`import ApolloAPI`); on a suffixed runtime the target
    is compiled with aliases so that resolves to that runtime's Apollo iOS. Every other
    module is imported by its real name: a variant on another runtime is explicit
    (`import CharactersGraphQL_v2`).

    Modules on different runtimes may depend on each other only through APIs that don't
    expose Apollo or generated types (plain models, views, closures). See docs/MIGRATIONS.md.

    Args:
        name: target name.
        runtime: the one runtime this module is on. Target and module keep their names.
        runtimes: instead, build a variant per runtime, for shared code such as networking
            that modules on every runtime use. Named like the other variants (plain on the
            home runtime, suffixed elsewhere). Use `#if APOLLO_IOS_2` where code must differ.
        srcs: Swift sources.
        deps: deps that don't depend on a runtime (plain Swift modules).
        runtime_deps: runtime-aware targets (schemas, operations, mocks, libraries built with
            `runtimes`); the variant on this target's runtime is used.
        apollo_deps: Apollo iOS libraries of the runtime to depend on: "ApolloAPI", "Apollo",
            "ApolloTestSupport".
        module_name: Swift module name. Defaults to the target name.
        **kwargs: forwarded to swift_library.
    """
    if bool(runtime) == bool(runtimes):
        fail("%s: set exactly one of `runtime` or `runtimes`." % name)
    for dep in apollo_deps:
        if dep not in _APOLLO_DEPS:
            fail("%s: unknown apollo_deps entry %r; use %s." % (name, dep, ", ".join(_APOLLO_DEPS)))
    copts = kwargs.pop("copts", [])
    visibility = kwargs.pop("visibility", None)
    tags = kwargs.pop("tags", [])
    variants = [(_runtime(runtime), "")] if runtime else _variants(None, runtimes)
    for rt, suffix in variants:
        swift_library(
            name = name + suffix,
            module_name = (module_name or name) + suffix,
            srcs = srcs,
            deps = deps + [_on(d, rt) for d in runtime_deps] + [getattr(rt, _APOLLO_DEPS[d]) for d in apollo_deps],
            copts = _copts(rt) + copts,
            visibility = visibility,
            tags = tags,
            **kwargs
        )
        if runtimes:
            _alias_variant(name, rt, suffix, visibility, tags, codegen = False)
