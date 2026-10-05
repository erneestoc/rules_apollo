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
schema, operations and mocks macros create one variant per runtime instead:
`<name><suffix>` and `<name><suffix>_apollo`, e.g. `MyAPI` and `MyAPI_v2`. The Apollo
iOS libraries come from the runtime, so `apollo_api` / `apollo_test_support` are not
needed. Bazel only builds the variants something depends on. Your own code picks a
runtime with `apollo_swift_library(runtime = ...)`. With runtimes, a schema target's
name must equal its `schema_namespace`, and a module's name must equal its target
name: aliases are derived from target names.
"""

load("@apollo_runtimes//:defs.bzl", "RUNTIMES")
load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")
load("//apollo:defs.bzl", "apollo_mock_partition_test", "apollo_mock_partition_update", "apollo_operations", "apollo_schema", "apollo_test_mocks")
load("//apollo/private:runtime_repositories.bzl", "runtime_aliases", "runtime_defines")

_CODEGEN_SUFFIX = "_apollo"

def _label(label, suffix = "", codegen = False):
    label = native.package_relative_label(label)
    return label.same_package_label(label.name + suffix + (_CODEGEN_SUFFIX if codegen else ""))

def _encode(value):
    return json.encode(value) if value else None

def _runtimes(runtimes):
    """The runtimes to create variants for; [None] means "no runtimes" (single version)."""
    if runtimes == None:
        return [RUNTIMES[k] for k in sorted(RUNTIMES)] if RUNTIMES else [None]
    return [_runtime(r) for r in runtimes]

def _runtime(name):
    if name not in RUNTIMES:
        fail("Unknown Apollo runtime %r. Declared with apollo.runtime(): %s" %
             (name, ", ".join(sorted(RUNTIMES)) or "none"))
    return RUNTIMES[name]

def _suffix(rt):
    return rt.suffix if rt else ""

def _copts(rt, aliased = [], own_module = None):
    """Swift flags for a target on runtime `rt`.

    Apollo module aliases, the version define, and aliases for the runtime-variant
    modules (named after their targets) it imports.
    """
    if not rt:
        return []
    flags = runtime_aliases(rt.suffix) + runtime_defines(rt.version)
    modules = [native.package_relative_label(dep).name for dep in aliased]
    if own_module:
        # Generated code refers to its own module by name (`MyAPI.Objects.Dog`).
        modules.append(own_module)
    if rt.suffix:
        for module in modules:
            flags += ["-module-alias", "%s=%s%s" % (module, module, rt.suffix)]
    return flags

def _require(value, what, rt):
    if not rt and not value:
        fail("`%s` is required when no apollo.runtime() is declared." % what)
    return value

def apollo_runtime(name):
    """Looks up a declared runtime, for BUILD files that use the rules directly.

    Args:
        name: name of an apollo.runtime().

    Returns:
        struct with `version`, `suffix`, and labels `cli`, `apollo_api`, `apollo`,
        `apollo_test_support`.
    """
    return _runtime(name)

# buildifier: disable=unnamed-macro
def apollo_runtime_copts(runtime, runtime_deps = [], modules = []):
    """Swift copts for a target of your own on `runtime`, for rules other than apollo_swift_library.

    Args:
        runtime: name of an apollo.runtime().
        runtime_deps: runtime-variant targets it imports (schema, operations, mocks, libraries),
            aliased by their target names.
        modules: other module names to alias to `<name><suffix>`, e.g. the schema namespace
            when compiling generated code of your own.

    Returns:
        list of copts.
    """
    rt = _runtime(runtime)
    flags = _copts(rt, runtime_deps)
    if rt.suffix:
        for module in modules:
            flags += ["-module-alias", "%s=%s%s" % (module, module, rt.suffix)]
    return flags

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
        runtimes = None,
        swift_srcs = [],
        deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates schema types and compiles them into a Swift module named `schema_namespace`.

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
        runtimes: runtime names to create variants for. Defaults to every declared runtime.
        swift_srcs: extra Swift sources for the module (custom scalars, extensions).
        deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    namespace = schema_namespace or name
    copts = kwargs.pop("copts", [])
    for rt in _runtimes(runtimes):
        if rt and namespace != name:
            fail("%s: with runtimes, the schema target's name must equal schema_namespace (%s)." % (name, namespace))
        suffix = _suffix(rt)
        apollo_schema(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = schema,
            srcs = srcs,
            schema_namespace = namespace,
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
            copts = _copts(rt, own_module = namespace) + copts,
            visibility = visibility,
            tags = tags,
            **kwargs
        )

def apollo_swift_operations(
        name,
        schema,
        apollo_api = None,
        srcs = [],
        deps = [],
        module_name = None,
        access_modifier = "public",
        runtimes = None,
        swift_srcs = [],
        swift_deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates one framework's operations and compiles them into a Swift module.

    Args:
        name: swift_library name. `module_name` defaults to it.
        schema: an apollo_swift_schema target.
        apollo_api: label of the ApolloAPI swift_library. Not used with runtimes.
        srcs: .graphql files owned by this module.
        deps: other apollo_swift_operations whose fragments these operations use.
        module_name: Swift module name.
        access_modifier: "public" or "internal".
        runtimes: runtime names to create variants for. Defaults to every declared runtime.
        swift_srcs: extra Swift sources for the module.
        swift_deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    module = module_name or name
    copts = kwargs.pop("copts", [])
    for rt in _runtimes(runtimes):
        suffix = _suffix(rt)
        apollo_operations(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = _label(schema, suffix, codegen = True),
            srcs = srcs,
            deps = [_label(d, suffix, codegen = True) for d in deps],
            module_name = module + suffix,
            access_modifier = access_modifier,
            visibility = visibility,
            tags = tags,
        )
        swift_library(
            name = name + suffix,
            module_name = module + suffix,
            srcs = [name + suffix + _CODEGEN_SUFFIX] + swift_srcs,
            deps = [_label(schema, suffix), rt.apollo_api if rt else _require(apollo_api, "apollo_api", rt)] +
                   [_label(d, suffix) for d in deps] + swift_deps,
            copts = _copts(rt, [schema]) + copts,
            visibility = visibility,
            tags = tags,
            **kwargs
        )

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
        shards = 4,
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
        shards: number of generated Swift files.
        runtimes: runtime names to create variants for. Defaults to every declared runtime.
        swift_srcs: hand-written test helpers compiled into the same module.
        deps: extra Swift deps.
        visibility: visibility of the targets.
        tags: tags for the targets.
        **kwargs: forwarded to swift_library.
    """
    module = module_name or name
    copts = kwargs.pop("copts", [])
    for rt in _runtimes(runtimes):
        suffix = _suffix(rt)
        apollo_test_mocks(
            name = name + suffix + _CODEGEN_SUFFIX,
            schema = _label(schema, suffix, codegen = True),
            base = _label(base, suffix, codegen = True) if base else None,
            operations = [_label(o, suffix, codegen = True) for o in operations],
            srcs = srcs,
            types = types,
            exclude_types = exclude_types,
            module_name = module + suffix,
            access_modifier = access_modifier,
            shards = shards,
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
                _label(schema, suffix),
                rt.apollo_api if rt else _require(apollo_api, "apollo_api", rt),
                rt.apollo_test_support if rt else _require(apollo_test_support, "apollo_test_support", rt),
            ] + ([_label(base, suffix)] if base else []) + deps,
            copts = _copts(rt, [schema]) + copts,
            testonly = True,
            visibility = visibility,
            tags = tags,
            **kwargs
        )

def apollo_swift_mock_partition(name, base, feature_mocks, runtimes = None, visibility = None, tags = []):
    """Declares `<name>` (the partition test) and `<name>_update` (bazel run to fix it).

    With runtimes, one pair per runtime: `<name><suffix>` and `<name><suffix>_update`.

    Args:
        name: test name.
        base: the base apollo_swift_test_mocks.
        feature_mocks: every feature apollo_swift_test_mocks with that base.
        runtimes: runtime names to create variants for. Defaults to every declared runtime.
        visibility: visibility of the targets.
        tags: tags for the targets.
    """
    for rt in _runtimes(runtimes):
        suffix = _suffix(rt)
        common = dict(
            base = _label(base, suffix, codegen = True),
            feature_mocks = [_label(f, suffix, codegen = True) for f in feature_mocks],
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

    Write the code as usual (`import ApolloAPI`, `import MyAPI`, `import FeedGraphQL`).
    On a runtime with a module suffix, the target is compiled with module aliases so
    those imports resolve to that runtime's modules. Migrating a module to another
    Apollo version is changing `runtime`.

    Modules on different runtimes may depend on each other only through APIs that don't
    expose Apollo or generated types (plain models, views, closures). See docs/MIGRATIONS.md.

    Args:
        name: target name.
        runtime: the one runtime this module is on. Target and module keep their names.
        runtimes: instead, build a variant per runtime (`<name><suffix>`), for shared code
            such as networking that modules on every runtime use. Use `-D APOLLO_IOS_<major>`
            (`#if APOLLO_IOS_2`) where the code must differ by version.
        srcs: Swift sources.
        deps: deps that don't depend on a runtime (plain Swift modules).
        runtime_deps: runtime-variant targets this module imports: schemas, operations,
            mocks and `apollo_swift_library(runtimes = ...)` targets. The matching variant is used.
        apollo_deps: Apollo iOS libraries of the runtime to depend on: "ApolloAPI", "Apollo",
            "ApolloTestSupport".
        module_name: Swift module name. Defaults to the target name.
        **kwargs: forwarded to swift_library.
    """
    if bool(runtime) == bool(runtimes):
        fail("%s: set exactly one of `runtime` or `runtimes`." % name)
    copts = kwargs.pop("copts", [])
    variants = [(_runtime(runtime), "")] if runtime else [(_runtime(r), _runtime(r).suffix) for r in runtimes]
    for rt, own_suffix in variants:
        for dep in apollo_deps:
            if dep not in _APOLLO_DEPS:
                fail("%s: unknown apollo_deps entry %r; use %s." % (name, dep, ", ".join(_APOLLO_DEPS)))
        swift_library(
            name = name + own_suffix,
            module_name = (module_name or name) + own_suffix,
            srcs = srcs,
            deps = deps + [_label(d, rt.suffix) for d in runtime_deps] +
                   [getattr(rt, _APOLLO_DEPS[d]) for d in apollo_deps],
            copts = _copts(rt, runtime_deps) + copts,
            **kwargs
        )
