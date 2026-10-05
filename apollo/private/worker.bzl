"""Helpers for running apollo-ios-cli as a Bazel persistent worker."""

def codegen_args(ctx, config, output_dir, mode, generate_for = [], extra = []):
    """Arguments for `apollo-ios-cli generate` in Bazel mode.

    Everything goes into a params file so the action works both as a worker
    request and as a plain spawn (the CLI expands `@file` itself).

    Args:
        ctx: rule context.
        config: full JSON config string.
        output_dir: tree artifact to generate into.
        mode: "schema_types", "operations" or "test_mocks".
        generate_for: list[File] selecting the operations and fragments to generate
            (operations mode) or the `referenced` mock scope (test_mocks mode).
        extra: additional flags.

    Returns:
        Args
    """
    args = ctx.actions.args()
    args.add("generate")
    args.add("--string", config)
    args.add("--bazel-output-dir", output_dir.path)
    args.add("--bazel-mode", mode)
    args.add_all(generate_for, before_each = "--bazel-generate-for")
    args.add_all(extra)
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    return args

def codegen_execution_requirements():
    return {
        "supports-workers": "1",
        # One process per schema serves concurrent requests from a single
        # parsed schema. The CLI ignores WorkRequest.sandbox_dir, so we do not
        # declare supports-multiplex-sandboxing: with --worker_sandboxing Bazel
        # falls back to sandboxed singleplex workers.
        "supports-multiplex-workers": "1",
        "requires-worker-protocol": "proto",
    }

def worker_env(schema_label):
    """Environment that becomes part of the worker key.

    Bazel keys persistent workers on (mnemonic, startup args, env, tool digest).
    Putting the schema label in the env gives every schema its own worker, so two
    schemas building interleaved never evict each other's parsed schema.

    Args:
        schema_label: Label of the apollo_schema.

    Returns:
        dict
    """
    return {"APOLLO_WORKER_SCHEMA": str(schema_label)}
