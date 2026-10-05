"""apollo_test_mocks and the mock partition test/updater. See docs/MOCKS.md."""

load(":config.bzl", "codegen_config")
load(":providers.bzl", "ApolloOperationsInfo", "ApolloSchemaInfo", "ApolloTestMocksInfo")
load(":shard.bzl", "shard_swift_sources")
load(":toolchain.bzl", "APOLLO_TOOLCHAIN_TYPE", "resolve_cli_for_schema")
load(":worker.bzl", "codegen_args", "codegen_execution_requirements", "worker_env")

_TOOLCHAINS = [config_common.toolchain_type(APOLLO_TOOLCHAIN_TYPE, mandatory = False)]

def _run_test_mocks(ctx, schema, out, access_modifier = "public", generate_for = [], extra = []):
    """Runs `generate --bazel-mode test_mocks` into `out`.

    Every mocks action compiles the whole app's operations: a mock's fields are
    the union of the fields every operation selects on its type, so a narrower
    input set would produce different files (MOCKS.md §2.4). `generate_for` only
    picks the `referenced` scope.
    """
    cli = resolve_cli_for_schema(ctx, schema)
    config = codegen_config(
        schema.config,
        schema.schema_files.to_list(),
        schema.operation_files.to_list(),
        test_mocks = {"absolute": {"path": "TestMocks", "accessModifier": access_modifier}},
    )
    ctx.actions.run(
        executable = cli.cli,
        arguments = [codegen_args(ctx, config, out, "test_mocks", generate_for = generate_for, extra = extra)],
        inputs = depset(transitive = [schema.schema_files, schema.operation_files]),
        outputs = [out],
        # Same mnemonic as the other codegen actions: one worker per schema serves
        # schema types, operations and mocks from one parsed schema.
        mnemonic = "ApolloCodegen",
        progress_message = "Generating Apollo test mocks %{label}",
        execution_requirements = codegen_execution_requirements(),
        env = worker_env(schema.label),
        toolchain = None if schema.cli_override else APOLLO_TOOLCHAIN_TYPE,
    )

def _check_scope(ctx, schema, scope_files):
    app = {f: True for f in schema.operation_files.to_list()}
    missing = [f.short_path for f in scope_files if f not in app]
    if missing:
        fail("%s: %s are not in the srcs of %s. Mocks compile the schema's operations, so every scoped file must be one of them." %
             (ctx.label, ", ".join(missing), schema.label))

def _apollo_test_mocks_impl(ctx):
    schema = ctx.attr.schema[ApolloSchemaInfo]
    module_name = ctx.attr.module_name or ctx.label.name
    base = ctx.attr.base[ApolloTestMocksInfo] if ctx.attr.base else None

    for op in ctx.attr.operations:
        if op[ApolloOperationsInfo].schema != schema.label:
            fail("%s: %s is generated against %s, not %s." % (ctx.label, op.label, op[ApolloOperationsInfo].schema, schema.label))
    scope_files = depset(ctx.files.srcs, transitive = [op[ApolloOperationsInfo].srcs for op in ctx.attr.operations])

    out = ctx.actions.declare_directory(ctx.label.name + "_test_mocks")
    if base:
        # Feature: the types its operations reference, minus what the base owns.
        if base.schema != schema.label:
            fail("%s: base %s uses schema %s, not %s." % (ctx.label, ctx.attr.base.label, base.schema, schema.label))
        if ctx.attr.exclude_types:
            fail("%s: `exclude_types` is only for the base; a feature excludes the base's `types`." % ctx.label)
        if not scope_files:
            fail("%s: a feature mocks target needs `operations` or `srcs` to define its scope." % ctx.label)
        _check_scope(ctx, schema, scope_files.to_list())
        extra = ["--bazel-mocks-scope", "referenced", "--bazel-mocks-base-module", base.module_name]
        extra += ["--bazel-mocks-exclude=" + t for t in base.types]
        generate_for = scope_files.to_list()

        # Features force extra types in (the CLI validates each name). The base's
        # `types` are declarative only: passing them would make a stale list fail
        # the build before the partition test can explain the fix.
        extra += ["--bazel-mocks-for=" + t for t in ctx.attr.types]
    else:
        # Base: every type except the feature-owned ones, plus the typealiases.
        if scope_files:
            fail("%s: the base has scope `all`; `operations` and `srcs` are for features (set `base` on them)." % ctx.label)
        extra = ["--bazel-mocks-exclude=" + t for t in ctx.attr.exclude_types]
        generate_for = []

    _run_test_mocks(ctx, schema, out, ctx.attr.access_modifier, generate_for, extra)

    return [
        DefaultInfo(files = depset(shard_swift_sources(ctx, out, ctx.attr.shards))),
        OutputGroupInfo(generated_tree = depset([out])),
        ApolloTestMocksInfo(
            schema = schema.label,
            schema_info = schema,
            module_name = module_name,
            base = ctx.attr.base.label if base else None,
            types = ctx.attr.types,
            exclude_types = ctx.attr.exclude_types,
            scope_files = scope_files,
            generated_tree = out,
            build_target = ctx.label.same_package_label(ctx.attr.build_target) if ctx.attr.build_target else ctx.label,
        ),
    ]

apollo_test_mocks = rule(
    implementation = _apollo_test_mocks_impl,
    doc = """Generates Apollo test mocks (`<Type>+Mock`) for one module of a partition.

Without `base`, this is the base module: every mocked type except `exclude_types`, plus the
`MockObject` typealiases. With `base`, it is a feature module: the types referenced by
`operations`/`srcs`, minus the base's `types`, importing the base module. A type is generated by
exactly one module; `apollo_mock_partition_test` checks that. See docs/MOCKS.md.""",
    attrs = {
        "schema": attr.label(mandatory = True, providers = [ApolloSchemaInfo]),
        "base": attr.label(
            providers = [ApolloTestMocksInfo],
            doc = "The base apollo_test_mocks. Unset means this target is the base.",
        ),
        "operations": attr.label_list(
            providers = [ApolloOperationsInfo],
            doc = "Features: apollo_operations whose srcs define the `referenced` scope.",
        ),
        "srcs": attr.label_list(
            allow_files = [".graphql"],
            doc = "Features: extra .graphql files for the scope. They must be in the schema's srcs.",
        ),
        "types": attr.string_list(
            doc = "Base: the owned types (excluded by every feature). Feature: extra types to include.",
        ),
        "exclude_types": attr.string_list(
            doc = "Base only: the feature-owned types the base must not generate.",
        ),
        "module_name": attr.string(doc = "Swift module of the mocks. Defaults to the target name."),
        "access_modifier": attr.string(default = "public", values = ["public", "internal"]),
        "shards": attr.int(default = 4, doc = "Number of Swift files the mocks are packed into."),
        "build_target": attr.string(
            doc = "Name of the target in this package that declares `types` (set by macros), for the updater.",
        ),
    },
    provides = [ApolloTestMocksInfo],
    toolchains = _TOOLCHAINS,
)

def _partition_impl(ctx, mode):
    base = ctx.attr.base[ApolloTestMocksInfo]
    if base.base:
        fail("%s: `base` must be the base mocks target, but %s has a base itself." % (ctx.label, ctx.attr.base.label))
    schema = base.schema_info

    # What a single, unscoped TestSupport gets today, and each feature's full reference set.
    reference = ctx.actions.declare_directory(ctx.label.name + "_reference")
    _run_test_mocks(ctx, schema, reference)

    # The updater only needs the reference sets, so a stale declaration (which can
    # break the base or a feature) never blocks the tool that fixes it.
    trees = [reference] if mode == "update" else [reference, base.generated_tree]

    lines = [
        "reference\t" + reference.short_path,
        "base\t%s\t%s\t%s" % (base.generated_tree.short_path, base.module_name, _buildozer_label(base.build_target)),
        "declared_types\t" + " ".join(sorted(base.types)),
        "declared_exclude\t" + " ".join(sorted(base.exclude_types)),
    ]
    for i, feature in enumerate(ctx.attr.feature_mocks):
        info = feature[ApolloTestMocksInfo]
        if info.base != ctx.attr.base.label:
            fail("%s: feature %s has base %s, not %s." % (ctx.label, feature.label, info.base, ctx.attr.base.label))
        ref = ctx.actions.declare_directory("%s_ref_%d" % (ctx.label.name, i))
        _run_test_mocks(ctx, schema, ref, generate_for = info.scope_files.to_list(), extra = ["--bazel-mocks-scope", "referenced"])
        trees += [ref] if mode == "update" else [info.generated_tree, ref]
        lines.append("feature\t%s\t%s\t%s\t%s" % (feature.label, info.generated_tree.short_path, info.module_name, ref.short_path))

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "\n".join(lines) + "\n")

    runfiles = ctx.runfiles(files = [ctx.file._script, manifest] + trees)
    buildozer = ""
    if mode == "update":
        buildozer = ctx.executable._buildozer.short_path
        runfiles = runfiles.merge(ctx.attr._buildozer[DefaultInfo].default_runfiles)

    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(executable, """\
#!/usr/bin/env bash
BUILDOZER="{buildozer}" exec bash "{script}" {mode} "{manifest}" "$@"
""".format(buildozer = buildozer, script = ctx.file._script.short_path, mode = mode, manifest = manifest.short_path), is_executable = True)

    return [DefaultInfo(executable = executable, runfiles = runfiles)]

def _partition_test_impl(ctx):
    return _partition_impl(ctx, "check")

def _partition_update_impl(ctx):
    return _partition_impl(ctx, "update")

def _buildozer_label(label):
    prefix = "@%s" % label.repo_name if label.repo_name else ""
    return "%s//%s:%s" % (prefix, label.package, label.name)

_PARTITION_ATTRS = {
    "base": attr.label(mandatory = True, providers = [ApolloTestMocksInfo]),
    "feature_mocks": attr.label_list(providers = [ApolloTestMocksInfo]),
    "_script": attr.label(default = ":mock_partition.sh", allow_single_file = True),
}

apollo_mock_partition_test = rule(
    implementation = _partition_test_impl,
    doc = """Checks that base + features is an exact partition of the unscoped mocks.

Fails when a type is generated twice, a type is missing, a file differs from the unscoped
output (other than the `import <base>` line), a feature carries the typealiases, or the base's
declared `types` / `exclude_types` are stale. The failure prints the lists to declare.""",
    attrs = _PARTITION_ATTRS,
    test = True,
    toolchains = _TOOLCHAINS,
)

apollo_mock_partition_update = rule(
    implementation = _partition_update_impl,
    doc = "`bazel run` target that rewrites the base's `types` / `exclude_types` with buildozer.",
    attrs = dict(_PARTITION_ATTRS, _buildozer = attr.label(
        default = "@buildozer//:buildozer",
        executable = True,
        cfg = "target",
    )),
    executable = True,
    toolchains = _TOOLCHAINS,
)
