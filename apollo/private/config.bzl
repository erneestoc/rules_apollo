"""Builds apollo-codegen-config.json documents for Bazel actions.

Users configure codegen with the same keys as Apollo's apollo-codegen-config.json
(`options`, `experimentalFeatures`, `operationManifest`). The rules own `input` and
`output`: inputs are the exact files Bazel tracks (never globs), and outputs go to
declared tree artifacts.
"""

# Options that only exist from a given Apollo iOS version on. Passing them to an
# older CLI fails config parsing, so we reject them at analysis time instead.
_VERSIONED_OPTIONS = {
    "reduceGeneratedSchemaTypes": "1.18.0",
    "markTypesNonisolated": "2.1.0",
    "additionalCapitalizationRules": "2.3.0",
}

# Options that fight with Bazel's ownership of the output tree.
_RULE_OWNED_OPTIONS = {
    "pruneGeneratedFiles": "Bazel owns the output tree; pruning is always disabled.",
    "cocoapodsCompatibleImportStatements": "Generated code is compiled by Bazel, not CocoaPods.",
}

def parse_version(version):
    """Parses "1.2.3" (optionally with a "-suffix") into a comparable tuple.

    Args:
        version: version string.

    Returns:
        tuple of three ints.
    """
    core = version.split("-")[0]
    parts = core.split(".")
    if len(parts) != 3:
        fail("Invalid Apollo iOS version %r, expected MAJOR.MINOR.PATCH" % version)
    return tuple([int(p) for p in parts])

def _decode_object(label, attr_name, value):
    if not value:
        return {}
    decoded = json.decode(value)
    if type(decoded) != "dict":
        fail("%s: `%s` must be a JSON object, got %s" % (label, attr_name, type(decoded)))
    return decoded

def build_base_config(ctx, version):
    """Builds the user-configurable part of the codegen config for an apollo_schema.

    Args:
        ctx: apollo_schema rule context.
        version: Apollo iOS version of the CLI that will consume the config.

    Returns:
        dict without `input`/`output`, ready for json.encode.
    """
    label = ctx.label
    options = _decode_object(label, "options", ctx.attr.options)
    experimental = _decode_object(label, "experimental_features", ctx.attr.experimental_features)

    for key, reason in _RULE_OWNED_OPTIONS.items():
        if key in options:
            fail("%s: option `%s` is managed by rules_apollo. %s" % (label, key, reason))

    v = parse_version(version)
    for key, min_version in _VERSIONED_OPTIONS.items():
        if key in options and v < parse_version(min_version):
            fail("%s: option `%s` requires Apollo iOS >= %s, but this schema uses %s" %
                 (label, key, min_version, version))

    options["pruneGeneratedFiles"] = False

    config = {
        "schemaNamespace": ctx.attr.schema_namespace or ctx.label.name,
        "options": options,
    }
    if experimental:
        config["experimentalFeatures"] = experimental
    return config

def codegen_config(base, schema_files, operation_files, access_modifier = None, test_mocks = None):
    """Returns the full JSON config for one codegen action.

    Args:
        base: dict from build_base_config.
        schema_files: list[File] schema inputs.
        operation_files: list[File] .graphql inputs (generated and fragment-only).
        access_modifier: access modifier for generated operations, if any.
        test_mocks: `output.testMocks` value; None disables mocks.

    Returns:
        JSON string.
    """
    operations = {"path": "."}
    if access_modifier:
        operations["accessModifier"] = access_modifier

    config = dict(base)
    config["input"] = {
        # Exact paths, never globs: the CLI only sees what Bazel declared.
        "schemaSearchPaths": [f.path for f in schema_files],
        "operationSearchPaths": [f.path for f in operation_files],
    }
    config["output"] = {
        # With --bazel-output-dir set, the CLI writes under that directory and
        # ignores these paths; they only select the module layout.
        "schemaTypes": {"path": ".", "moduleType": {"other": {}}},
        "operations": {"absolute": operations},
        "testMocks": test_mocks or {"none": {}},
    }
    return json.encode(config)
