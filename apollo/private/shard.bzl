"""Turns a tree artifact of generated Swift into a fixed set of declared files.

Swift rules handle directories of sources poorly: rules_swift declares one object
file per source File, and a tree artifact is a single File. Codegen output names
are only known after running the CLI, so instead we concatenate the generated
files into `count` declared shards. Each file goes to the shard picked by a hash
of its path, so adding or removing one type rewrites only one shard and Swift
still compiles the module in parallel, file by file.

Concatenation is safe because generated files only contain imports (legal
anywhere at file scope) and declarations with no file-private top-level names.
"""

_AWK = r"""
BEGIN {
  for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
  for (i = 0; i < n; i++) printf "" > out[i]
}
{
  path = $0
  rel = substr(path, length(dir) + 2)
  if (rel in skip) next
  h = 0
  for (i = 1; i <= length(rel); i++) h = (h * 31 + ord[substr(rel, i, 1)]) % 1000003
  o = out[h % n]
  printf "// rules_apollo: %s\n", rel >> o
  while ((getline line < path) > 0) print line >> o
  close(path)
  print "" >> o
}
"""

def shard_swift_sources(ctx, tree, count, exclude = []):
    """Declares `count` Swift files and fills them from `tree`.

    Args:
        ctx: rule context.
        tree: tree artifact of generated .swift files.
        count: number of shards.
        exclude: paths relative to `tree` to leave out (e.g. files the user replaces).

    Returns:
        list[File]
    """
    if count < 1:
        fail("%s: shards must be >= 1" % ctx.label)
    shards = [
        ctx.actions.declare_file("%s_%d.swift" % (tree.basename, i))
        for i in range(count)
    ]

    args = ctx.actions.args()
    args.add(tree.path)
    args.add_all(shards)

    # `awk -v out[i]=` is not portable, so pass the shard paths as a list file
    # through ARGV and split it in BEGIN.
    ctx.actions.run_shell(
        inputs = [tree],
        outputs = shards,
        arguments = [args],
        command = """\
set -eu
dir="$1"; shift
outs="$*"
find -L "$dir" -type f -name '*.swift' | LC_ALL=C sort | awk -v dir="$dir" -v n="$#" -v outs="$outs" -v skips="$SKIP" '
BEGIN {
  split(outs, out, " "); for (i = 0; i < n; i++) out[i] = out[i + 1]
  ns = split(skips, s, " "); for (i = 1; i <= ns; i++) skip[s[i]] = 1
}
""" + _AWK + "'\n",
        env = {"SKIP": " ".join(exclude)},
        mnemonic = "ApolloShard",
        progress_message = "Sharding generated Swift for %{label}",
    )
    return shards
