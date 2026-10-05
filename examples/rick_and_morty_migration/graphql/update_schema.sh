#!/usr/bin/env bash
# Re-fetches graphql/schema.graphqls from the live API by introspection.
# Needs Node.js 18+ (for fetch); installs graphql-js into a temp dir.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && npm init -y > /dev/null && npm install --silent graphql@16 > /dev/null)
cat > "$tmp/fetch.mjs" <<'JS'
import { getIntrospectionQuery, buildClientSchema, printSchema } from "graphql";
const res = await fetch("https://rickandmortyapi.com/graphql", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ query: getIntrospectionQuery() }),
});
const { data } = await res.json();
process.stdout.write(printSchema(buildClientSchema(data)) + "\n");
JS
node "$tmp/fetch.mjs" > schema.graphqls
echo "Updated $(pwd)/schema.graphqls"
