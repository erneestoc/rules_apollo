#!/usr/bin/env bash
# Runs examples/animal_kingdom end to end against several Apollo iOS versions:
# codegen with that version's CLI, then compile, link and test against that
# version's Apollo iOS runtime.
#
# Usage: tools/version_matrix.sh [VERSION...]   (default: a spread across 1.x and 2.x)
# Env:   WORK_DIR   where the per-version copies go (default: a temp dir)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
VERSIONS=("$@")
[ ${#VERSIONS[@]} -gt 0 ] || VERSIONS=(1.15.1 1.18.0 1.21.0 1.24.0 1.25.3 2.0.3 2.2.0 2.4.0)

results=()
for v in "${VERSIONS[@]}"; do
  dir="$WORK_DIR/$v"
  log="$WORK_DIR/$v.log"
  rm -rf "$dir"
  mkdir -p "$dir"
  (cd "$ROOT/examples/animal_kingdom" && tar cf - --exclude './bazel-*' .) | (cd "$dir" && tar xf -)

  url="https://github.com/apollographql/apollo-ios/archive/refs/tags/$v.tar.gz"
  sha="$(curl -sfL "$url" | shasum -a 256 | cut -d' ' -f1)"

  # Point the copy at this version: CLI toolchain, runtime archive, rules path.
  python3 - "$dir" "$v" "$sha" "$url" "$ROOT" <<'EOF'
import re, sys
d, v, sha, url, root = sys.argv[1:]
p = f"{d}/MODULE.bazel"
s = open(p).read()
s = re.sub(r'apollo\.toolchain\(version = "[^"]+"\)', f'apollo.toolchain(version = "{v}")', s)
s = re.sub(r'sha256 = "[0-9a-f]+"', f'sha256 = "{sha}"', s)
s = re.sub(r'strip_prefix = "apollo-ios-[^"]+"', f'strip_prefix = "apollo-ios-{v}"', s)
s = re.sub(r'urls = \["[^"]+"\]', f'urls = ["{url}"]', s)
s = s.replace('path = "../.."', f'path = "{root}"')
open(p, "w").write(s)
if v.startswith("1."):
    # Apollo iOS 1.x is Swift 5 language mode.
    p = f"{d}/third_party/apollo_ios.BUILD"
    s = open(p).read().replace('"-swift-version", "6"', '"-swift-version", "5"')
    open(p, "w").write(s)
EOF

  echo "=== $v"
  if (cd "$dir" && bazel test //... > "$log" 2>&1); then
    results+=("$v PASS $(grep -Eo 'Executed [0-9]+ out of [0-9]+ tests?: .*' "$log" | tail -1)")
  else
    results+=("$v FAIL (see $log)")
  fi
  (cd "$dir" && bazel shutdown > /dev/null 2>&1) || true
  echo "${results[${#results[@]}-1]}"
done

echo
printf '%s\n' "${results[@]}"
for r in "${results[@]}"; do [[ "$r" == *PASS* ]] || exit 1; done
