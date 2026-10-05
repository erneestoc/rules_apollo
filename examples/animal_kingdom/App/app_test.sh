#!/usr/bin/env bash
set -euo pipefail
expected=$'AllAnimalsQuery\ntrue\nDog'
actual="$("$1")"
if [[ "$actual" != "$expected" ]]; then
  echo "expected:"; echo "$expected"; echo "actual:"; echo "$actual"
  exit 1
fi
