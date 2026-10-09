"""Analysis tests for rules_apollo."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//apollo:defs.bzl", "ApolloSchemaInfo")

def _find_codegen_action(env):
    for action in analysistest.target_actions(env):
        if action.mnemonic == "ApolloCodegen":
            return action
    fail("no ApolloCodegen action")

def _values(argv, flag):
    """Values of a repeatable flag, in `--flag value` or `--flag=value` form."""
    values = []
    for i, arg in enumerate(argv):
        if arg == flag:
            values.append(argv[i + 1])
        elif arg.startswith(flag + "="):
            values.append(arg[len(flag) + 1:])
    return values

def _config(argv):
    return json.decode(_values(argv, "--string")[0])

def _output_basenames(env):
    return sorted([f.basename for f in analysistest.target_under_test(env)[DefaultInfo].files.to_list()])

def _schema_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    argv = _find_codegen_action(env).argv

    asserts.equals(env, ["schema_types"], _values(argv, "--bazel-mode"))
    asserts.true(env, "--bazel-keep-schema-configuration" in argv, "expected --bazel-keep-schema-configuration")

    config = _config(argv)
    asserts.equals(env, ["tests/analysis/schema.graphqls"], config["input"]["schemaSearchPaths"])
    asserts.equals(
        env,
        sorted(["tests/analysis/a/A.graphql", "tests/analysis/other/Other.graphql"]),
        sorted(config["input"]["operationSearchPaths"]),
    )
    asserts.equals(env, {"none": {}}, config["output"]["testMocks"])
    asserts.equals(env, False, config["options"]["pruneGeneratedFiles"])
    asserts.equals(env, "include", config["options"]["schemaDocumentation"])
    asserts.equals(env, "TestAPI", target[ApolloSchemaInfo].namespace)

    # The CLI's output directory is the module's sources as is.
    asserts.equals(env, ["schema_schema_types"], _output_basenames(env))
    return analysistest.end(env)

schema_action_test = analysistest.make(_schema_action_test_impl)

def _operations_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _find_codegen_action(env)
    argv = action.argv
    asserts.equals(env, ["operations"], _values(argv, "--bazel-mode"))

    # Inputs are own srcs plus the deps' fragments; only own srcs are generated.
    config = _config(argv)
    asserts.equals(env, sorted(ctx.attr.inputs), sorted(config["input"]["operationSearchPaths"]))
    asserts.equals(env, ctx.attr.generated, _values(argv, "--bazel-generate-for"))
    asserts.equals(env, [], _values(argv, "--bazel-framework-path"))
    asserts.equals(env, {"path": ".", "accessModifier": "public"}, config["output"]["operations"]["absolute"])
    asserts.equals(env, Label("//tests/analysis:schema"), Label(action.env.get("APOLLO_WORKER_SCHEMA")))

    name = analysistest.target_under_test(env).label.name
    asserts.equals(env, sorted([name + "_operations", name + "_ApolloImports.swift"]), _output_basenames(env))
    return analysistest.end(env)

operations_action_test = analysistest.make(
    _operations_action_test_impl,
    attrs = {
        "inputs": attr.string_list(),
        "generated": attr.string_list(),
    },
)

def _mocks_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _find_codegen_action(env).argv
    asserts.equals(env, ["test_mocks"], _values(argv, "--bazel-mode"))

    # Every mocks action compiles the whole app (MOCKS.md §2.4).
    config = _config(argv)
    asserts.equals(
        env,
        sorted(["tests/analysis/a/A.graphql", "tests/analysis/other/Other.graphql"]),
        sorted(config["input"]["operationSearchPaths"]),
    )
    asserts.equals(env, {"absolute": {"path": "TestMocks", "accessModifier": "public"}}, config["output"]["testMocks"])

    asserts.equals(env, ctx.attr.scope, _values(argv, "--bazel-mocks-scope"))
    asserts.equals(env, ctx.attr.base_module, _values(argv, "--bazel-mocks-base-module"))
    asserts.equals(env, ctx.attr.excluded, _values(argv, "--bazel-mocks-exclude"))
    asserts.equals(env, ctx.attr.generate_for, _values(argv, "--bazel-generate-for"))

    # Mocks can generate nothing, so the module also gets a placeholder file.
    name = analysistest.target_under_test(env).label.name
    asserts.equals(env, sorted([name + "_test_mocks", name + "_Module.swift"]), _output_basenames(env))
    return analysistest.end(env)

mocks_action_test = analysistest.make(
    _mocks_action_test_impl,
    attrs = {
        "scope": attr.string_list(),
        "base_module": attr.string_list(),
        "excluded": attr.string_list(),
        "generate_for": attr.string_list(),
    },
)

def _schema_filter_test_impl(ctx):
    env = analysistest.begin(ctx)
    filters = [a for a in analysistest.target_actions(env) if a.mnemonic == "ApolloFilterSources"]
    asserts.equals(env, 1, len(filters))
    filtered = filters[0].outputs.to_list()

    # Replaced files are left out of a copy of the CLI's output directory.
    asserts.equals(env, ctx.attr.excluded, filters[0].argv[-len(ctx.attr.excluded):])
    asserts.equals(
        env,
        sorted([f.basename for f in filtered] + ctx.attr.extra_outputs),
        _output_basenames(env),
    )
    return analysistest.end(env)

schema_filter_test = analysistest.make(
    _schema_filter_test_impl,
    attrs = {
        "excluded": attr.string_list(),
        "extra_outputs": attr.string_list(),
    },
)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected)
    return analysistest.end(env)

failure_test = analysistest.make(
    _failure_test_impl,
    expect_failure = True,
    attrs = {"expected": attr.string(mandatory = True)},
)
