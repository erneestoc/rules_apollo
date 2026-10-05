#!/usr/bin/env bash
# Checks or updates an Apollo test mock partition (docs/MOCKS.md §3, §6).
#
#   mock_partition.sh check  MANIFEST   # apollo_mock_partition_test
#   mock_partition.sh update MANIFEST   # apollo_mock_partition_update (bazel run)
#
# The manifest (written by the rule) lists tree artifacts as runfiles paths:
#   reference         <tree>                          unscoped mocks (every type)
#   base              <tree> <module> <label>         the base module's mocks
#   declared_types    <types...>                      the base's `types`
#   declared_exclude  <types...>                      the base's `exclude_types`
#   feature           <label> <tree> <module> <ref>   a feature's mocks and its full referenced set
set -euo pipefail

mode="$1"
manifest="$2"
work="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/apollo_mocks.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Mock file names (relative to TestMocks/) in a tree, sorted.
mock_files() {
  if [ -d "$1/TestMocks" ]; then
    (cd "$1/TestMocks" && find -L . -type f -name '*.swift' | sed 's|^\./||' | LC_ALL=C sort)
  fi
}

# Object type names from mock file names ("Dog+Mock.graphql.swift" -> "Dog").
types_of() {
  { grep -v '^MockObject+' || true; } | sed 's/+Mock\..*$//' | LC_ALL=C sort -u
}

words_to_lines() { tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u; }

reference="" base_tree="" base_module="" base_label="" declared_types="" declared_exclude=""
: > "$work/features"
while IFS= read -r line; do
  kind="${line%%$'\t'*}"
  rest="${line#*$'\t'}"
  case "$kind" in
    reference) reference="$rest" ;;
    base) IFS=$'\t' read -r base_tree base_module base_label <<< "$rest" ;;
    declared_types) declared_types="$rest" ;;
    declared_exclude) declared_exclude="$rest" ;;
    feature) printf '%s\n' "$rest" >> "$work/features" ;;
  esac
done < "$manifest"

# Expected partition (MOCKS.md §3):
#  1. A type referenced by exactly one feature belongs to that feature; everything
#     else (shared, or referenced by none) belongs to the base.
#  2. Closure: mocks name other mocks in their fields (`@Field<Height>`). The base
#     cannot import a feature, and features cannot import each other, so a type
#     named by a base mock, or by another feature's mock, moves to the base.
mock_files "$reference" > "$work/reference_files"
types_of < "$work/reference_files" > "$work/all"
: > "$work/owners"
while IFS=$'\t' read -r label tree module ref; do
  mock_files "$ref" | types_of | sed "s|\$|\t$label|" >> "$work/owners"
done < "$work/features"

# Field references between mock types, from the unscoped mocks: "<type> <referenced type>".
: > "$work/edges"
while IFS= read -r t; do
  for f in "$reference/TestMocks/$t+Mock."*; do
    sed -n 's/.*@Field<\(.*\)>(".*/\1/p' "$f" |
      sed -E 's/[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_.]*//g' |
      grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sed "s|^|$t |" >> "$work/edges" || true
  done
done < "$work/all"

awk '
  FILENAME == ARGV[1] { all[$1] = 1; next }
  FILENAME == ARGV[2] { split($0, p, "\t"); n[p[1]]++; owner[p[1]] = p[2]; next }
  FILENAME == ARGV[3] { if ($2 in all) { e++; from[e] = $1; to[e] = $2 }; next }
  END {
    for (t in all) if (n[t] != 1) owner[t] = "base"
    do {
      changed = 0
      for (i = 1; i <= e; i++) {
        a = owner[from[i]]; b = owner[to[i]]
        if (b != "base" && b != a) { owner[to[i]] = "base"; changed = 1 }
      }
    } while (changed)
    for (t in all) print t "\t" owner[t]
  }' "$work/all" "$work/owners" "$work/edges" | LC_ALL=C sort > "$work/partition"
awk -F'\t' '$2 != "base" { print $1 }' "$work/partition" > "$work/expected_exclude"
awk -F'\t' '$2 == "base" { print $1 }' "$work/partition" > "$work/expected_types"

buildozer_commands() {
  local types exclude
  types="$(tr '\n' ' ' < "$work/expected_types" | sed 's/ $//')"
  exclude="$(tr '\n' ' ' < "$work/expected_exclude" | sed 's/ $//')"
  # `set` with several values on an attribute buildozer does not know writes a
  # bare word; `remove` + `add` always yields a list of strings.
  echo "remove types"
  [ -z "$types" ] || echo "add types $types"
  echo "remove exclude_types"
  [ -z "$exclude" ] || echo "add exclude_types $exclude"
}

if [ "$mode" = "update" ]; then
  commands=()
  while IFS= read -r c; do commands+=("$c"); done < <(buildozer_commands)
  # The rule passes buildozer from the registry (a runfiles path); fall back to PATH.
  if [ -n "${BUILDOZER:-}" ] && [ -x "$BUILDOZER" ]; then
    BUILDOZER="$(cd "$(dirname "$BUILDOZER")" && pwd)/$(basename "$BUILDOZER")"
  else
    BUILDOZER="$(command -v buildozer || true)"
  fi
  if [ -n "$BUILDOZER" ] && [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    export RUNFILES_DIR="${RUNFILES_DIR:-$(cd .. && pwd)}"
    cd "$BUILD_WORKSPACE_DIRECTORY"
    status=0
    "$BUILDOZER" "${commands[@]}" "$base_label" || status=$?
    # buildozer exits 3 when the file already matches.
    if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then exit "$status"; fi
    echo "Updated $base_label: types = [$(tr '\n' ' ' < "$work/expected_types")], exclude_types = [$(tr '\n' ' ' < "$work/expected_exclude")]"
  else
    echo "buildozer not found. Run:"
    printf "  buildozer"; printf " '%s'" "${commands[@]}"; printf " %s\n" "$base_label"
  fi
  exit 0
fi

errors=0
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

# 1. Every generated file, by module.
mock_files "$base_tree" | sed "s|^|base\t|" > "$work/generated"
while IFS=$'\t' read -r label tree module ref; do
  mock_files "$tree" | sed "s|^|$label\t|" >> "$work/generated"
  if mock_files "$tree" | grep -q '^MockObject+'; then
    fail "$label generates the MockObject typealiases; only the base may."
  fi
done < "$work/features"

cut -f2 "$work/generated" | LC_ALL=C sort | uniq -d > "$work/duplicates"
if [ -s "$work/duplicates" ]; then
  fail "generated by more than one module (a duplicate class at link time): $(types_of < "$work/duplicates" | tr '\n' ' ')"
fi

# 2. base ∪ features == unscoped reference, as a set of files.
cut -f2 "$work/generated" | LC_ALL=C sort -u > "$work/union"
missing="$(LC_ALL=C comm -23 "$work/reference_files" "$work/union" | tr '\n' ' ')"
extra="$(LC_ALL=C comm -13 "$work/reference_files" "$work/union" | tr '\n' ' ')"
[ -z "$missing" ] || fail "mocks no module generates: $missing"
[ -z "$extra" ] || fail "mocks not in the unscoped output: $extra"

# 3. Byte-identical to the reference, except the feature's `import <base>` line.
while IFS=$'\t' read -r owner file; do
  ref_file="$reference/TestMocks/$file"
  [ -f "$ref_file" ] || continue
  if [ "$owner" = "base" ]; then
    cmp -s "$base_tree/TestMocks/$file" "$ref_file" || fail "$file in the base differs from the unscoped output"
  else
    tree="$(awk -F'\t' -v l="$owner" '$1 == l { print $2 }' "$work/features")"
    grep -vx "import $base_module" "$tree/TestMocks/$file" | cmp -s - "$ref_file" ||
      fail "$file in $owner differs from the unscoped output"
  fi
done < "$work/generated"

# 4. The declared ownership matches the operations.
echo "$declared_types" | words_to_lines > "$work/declared_types"
echo "$declared_exclude" | words_to_lines > "$work/declared_exclude"
if ! cmp -s "$work/declared_types" "$work/expected_types" || ! cmp -s "$work/declared_exclude" "$work/expected_exclude"; then
  moved="$(LC_ALL=C comm -12 "$work/declared_exclude" "$work/expected_types" | tr '\n' ' ')"
  [ -z "$moved" ] || echo "  types that must move to the base (shared, or named by a base or another feature's mock): $moved"
  fail "the base's declared types/exclude_types are stale."
  echo "  expected types:         $(tr '\n' ' ' < "$work/expected_types")"
  echo "  expected exclude_types: $(tr '\n' ' ' < "$work/expected_exclude")"
fi

if [ "$errors" -gt 0 ]; then
  echo
  echo "Fix the declared partition with the update target (bazel run <partition>_update), or:"
  printf "  buildozer"
  while IFS= read -r c; do printf " '%s'" "$c"; done < <(buildozer_commands)
  printf " %s\n" "$base_label"
  exit 1
fi
echo "OK: $(wc -l < "$work/union" | tr -d ' ') mock files, each generated by exactly one module."
