#!/usr/bin/env bash
# Run every test/test-*.sh (or the ones named as arguments). Exits non-zero if
# any test script fails; prints the output of failing scripts.
set -uo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ $# -gt 0 ]; then
  tests=()
  for t in "$@"; do tests+=("$dir/$(basename "$t")"); done
else
  tests=("$dir"/test-*.sh)
fi

pass=0
failed=()
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for t in "${tests[@]}"; do
  [ -f "$t" ] || { echo "MISSING $(basename "$t")"; failed+=("$(basename "$t")"); continue; }
  if bash "$t" > "$log" 2>&1; then
    echo "PASS $(basename "$t")"
    pass=$((pass + 1))
  else
    echo "FAIL $(basename "$t")"
    sed 's/^/    /' "$log"
    failed+=("$(basename "$t")")
  fi
done

echo
echo "$pass passed, ${#failed[@]} failed${failed[*]:+: ${failed[*]}}"
[ ${#failed[@]} -eq 0 ]
