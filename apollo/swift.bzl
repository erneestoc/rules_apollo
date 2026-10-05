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
"""

load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")
load("//apollo:defs.bzl", "apollo_mock_partition_test", "apollo_mock_partition_update", "apollo_operations", "apollo_schema", "apollo_test_mocks")

_CODEGEN_SUFFIX = "_apollo"

def _codegen_label(label):
    label = native.package_relative_label(label)
    return label.same_package_label(label.name + _CODEGEN_SUFFIX)

def _encode(value):
    return json.encode(value) if value else None

def apollo_swift_schema(
        name,
        schema,
        apollo_api,
        srcs = [],
        schema_namespace = None,
        options = {},
        experimental_features = {},
        custom_scalars = [],
        schema_configuration = None,
        operation_manifest_version = None,
        cli = None,
        swift_srcs = [],
        deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates schema types and compiles them into a Swift module named `schema_namespace`.

    Args:
        name: swift_library name. `schema_namespace` defaults to it.
        schema: schema files (.graphqls or introspection .json).
        apollo_api: label of the ApolloAPI swift_library.
        srcs: every .graphql file of the app.
        schema_namespace: Swift module name and Apollo schemaNamespace.
        options: dict with apollo-codegen-config.json `options`.
        experimental_features: dict with `experimentalFeatures`.
        custom_scalars: custom scalars you implement in `swift_srcs` (drops the generated String typealias).
        schema_configuration: your SchemaConfiguration.swift.
        operation_manifest_version: "persistedQueries" or "legacy" to emit a manifest.
        cli: per-schema CLI override, e.g. "@apollo_next//:cli".
        swift_srcs: extra Swift sources for the module (custom scalars, extensions).
        deps: extra Swift deps.
        visibility: visibility of both targets.
        tags: tags for both targets.
        **kwargs: forwarded to swift_library.
    """
    apollo_schema(
        name = name + _CODEGEN_SUFFIX,
        schema = schema,
        srcs = srcs,
        schema_namespace = schema_namespace or name,
        options = _encode(options),
        experimental_features = _encode(experimental_features),
        custom_scalars = custom_scalars,
        schema_configuration = schema_configuration,
        operation_manifest_version = operation_manifest_version,
        cli = cli,
        visibility = visibility,
        tags = tags,
    )
    swift_library(
        name = name,
        module_name = schema_namespace or name,
        srcs = [name + _CODEGEN_SUFFIX] + swift_srcs,
        deps = [apollo_api] + deps,
        visibility = visibility,
        tags = tags,
        **kwargs
    )

def apollo_swift_operations(
        name,
        schema,
        apollo_api,
        srcs = [],
        deps = [],
        module_name = None,
        access_modifier = "public",
        swift_srcs = [],
        swift_deps = [],
        visibility = None,
        tags = [],
        **kwargs):
    """Generates one framework's operations and compiles them into a Swift module.

    Args:
        name: swift_library name. `module_name` defaults to it.
        schema: an apollo_swift_schema target.
        apollo_api: label of the ApolloAPI swift_library.
        srcs: .graphql files owned by this module (must be in this package).
        deps: other apollo_swift_operations whose fragments these operations use.
        module_name: Swift module name.
        access_modifier: "public" or "internal".
        swift_srcs: extra Swift sources for the module.
        swift_deps: extra Swift deps.
        visibility: visibility of both targets.
        tags: tags for both targets.
        **kwargs: forwarded to swift_library.
    """
    apollo_operations(
        name = name + _CODEGEN_SUFFIX,
        schema = _codegen_label(schema),
        srcs = srcs,
        deps = [_codegen_label(d) for d in deps],
        module_name = module_name or name,
        access_modifier = access_modifier,
        visibility = visibility,
        tags = tags,
    )
    swift_library(
        name = name,
        module_name = module_name or name,
        srcs = [name + _CODEGEN_SUFFIX] + swift_srcs,
        deps = [schema, apollo_api] + deps + swift_deps,
        visibility = visibility,
        tags = tags,
        **kwargs
    )

def apollo_swift_test_mocks(
        name,
        schema,
        apollo_api,
        apollo_test_support,
        base = None,
        operations = [],
        srcs = [],
        types = [],
        exclude_types = [],
        module_name = None,
        access_modifier = "public",
        shards = 4,
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
        apollo_api: label of the ApolloAPI swift_library.
        apollo_test_support: label of the ApolloTestSupport swift_library.
        base: the base apollo_swift_test_mocks. Unset for the base itself.
        operations: features: apollo_swift_operations whose operations define the scope.
        srcs: features: extra .graphql files for the scope.
        types: base: owned types (maintained by the partition updater). Feature: extra types.
        exclude_types: base only: feature-owned types (maintained by the partition updater).
        module_name: Swift module name.
        access_modifier: "public" or "internal".
        shards: number of generated Swift files.
        swift_srcs: hand-written test helpers compiled into the same module.
        deps: extra Swift deps.
        visibility: visibility of both targets.
        tags: tags for both targets.
        **kwargs: forwarded to swift_library.
    """
    apollo_test_mocks(
        name = name + _CODEGEN_SUFFIX,
        schema = _codegen_label(schema),
        base = _codegen_label(base) if base else None,
        operations = [_codegen_label(o) for o in operations],
        srcs = srcs,
        types = types,
        exclude_types = exclude_types,
        module_name = module_name or name,
        access_modifier = access_modifier,
        shards = shards,
        build_target = name,
        testonly = True,
        visibility = visibility,
        tags = tags,
    )
    swift_library(
        name = name,
        module_name = module_name or name,
        srcs = [name + _CODEGEN_SUFFIX] + swift_srcs,
        deps = [schema, apollo_api, apollo_test_support] + ([base] if base else []) + deps,
        testonly = True,
        visibility = visibility,
        tags = tags,
        **kwargs
    )

def apollo_swift_mock_partition(name, base, feature_mocks, visibility = None, tags = []):
    """Declares `<name>` (the partition test) and `<name>_update` (bazel run to fix it).

    Args:
        name: test name.
        base: the base apollo_swift_test_mocks.
        feature_mocks: every feature apollo_swift_test_mocks with that base.
        visibility: visibility of both targets.
        tags: tags for both targets.
    """
    common = dict(
        base = _codegen_label(base),
        feature_mocks = [_codegen_label(f) for f in feature_mocks],
        testonly = True,
        visibility = visibility,
        tags = tags,
    )
    apollo_mock_partition_test(name = name, **common)
    apollo_mock_partition_update(name = name + "_update", **common)
