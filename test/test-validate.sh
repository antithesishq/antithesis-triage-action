#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $ and backticks in expected strings
# Tests for scripts/validate-findings.sh.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/validate-findings.sh
fx=$root/test/fixtures
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }

# run <name> <file> <want_rc> [expected output substrings...]
run() {
  local name=$1 file=$2 want=$3 rc=0 out
  shift 3
  out=$("$script" "$file" 2>"$tmp/stderr") || rc=$?
  if [[ $rc -ne $want ]]; then not_ok "$name: exit $rc, want $want; output: $out"; return; fi
  local s
  for s in "$@"; do
    if [[ $out != *"$s"* ]]; then not_ok "$name: missing '$s' in output: $out"; return; fi
  done
  ok "$name"
}

# mutate <jq filter> -> path of a mutated copy of the valid fixture
mutate() {
  local f=$tmp/m$RANDOM.json
  jq "$1" "$fx/findings.json" >"$f"
  echo "$f"
}

run "valid fixture" "$fx/findings.json" 0
if [[ -n $("$script" "$fx/findings.json" 2>&1) ]]; then not_ok "valid fixture prints nothing"; else ok "valid fixture prints nothing"; fi

run "invalid fixture" "$fx/findings.invalid.json" 1 \
  '$: missing required key "errors"' \
  '$.schema_version: must be "0.1"' \
  '$.status: "done" is not one of' \
  '$.selection.runs_considered: -1 is less than the minimum 0' \
  '$.grouping.inferred: expected boolean, got string' \
  '$.runs[0]: unexpected key "extra"' \
  '$.runs[0].commit: expected string or null, got number' \
  '$.runs[0].properties_failed: expected integer, got number' \
  '$.runs[0].instrumentation: "fine" is not one of' \
  '$.failures[0]: missing required key "reproduce_commands"' \
  '$.failures[0].known_issue: missing required key "reason"' \
  '$.failures[0].known_issue.status: "maybe" is not one of' \
  '$.failures[0].confidence: "very high" is not one of' \
  '$.failures[0].source_refs[0].line: expected integer or null, got string'

n=$("$script" "$fx/findings.invalid.json" | wc -l)
if [[ $n -eq 14 ]]; then ok "one line per violation"; else not_ok "expected 14 violations, got $n"; fi

run "in_progress status is valid" "$(mutate '.status = "in_progress"')" 0
run "nullable fields accept null" "$(mutate '.failures[0].evidence[0].input_hash = null | .runs[0].commit = null')" 0
run "non-nullable string rejects null" "$(mutate '.failures[0].recommended_debug_session.input_hash = null')" 1 \
  '$.failures[0].recommended_debug_session.input_hash: expected string, got null'
run "missing nested required key" "$(mutate 'del(.failures[0].evidence[0].excerpt)')" 1 \
  '$.failures[0].evidence[0]: missing required key "excerpt"'
run "extra nested key" "$(mutate '.selection.extra = 1')" 1 '$.selection: unexpected key "extra"'
run "wrong array item type" "$(mutate '.run_health = ["ok", 3]')" 1 '$.run_health[1]: expected string, got number'
run "array where object expected" "$(mutate '.grouping = []')" 1 '$.grouping: expected object, got array'
run "integer accepts 2.0" "$(mutate '.selection.runs_considered = 2.0')" 0
run "top level not an object" "$(mutate '[.]')" 1 '$: expected object, got array'

printf 'not json' >"$tmp/bad.json"
run "not JSON" "$tmp/bad.json" 1 '$: not valid JSON'
printf '{} {}' >"$tmp/two.json"
run "two documents" "$tmp/two.json" 1 'expected exactly one JSON document'
run "missing file" "$tmp/nope.json" 1 'file not found'

# Unsupported schema keywords are reported, not silently ignored.
jq '.properties.summary.pattern = "^x"' "$root/schema/findings.schema.json" >"$tmp/schema.json"
"$script" "$fx/findings.json" "$tmp/schema.json" >/dev/null 2>"$tmp/stderr"
if grep -q 'properties.summary: unsupported schema keyword "pattern"' "$tmp/stderr"; then
  ok "unsupported keyword warning"
else
  not_ok "unsupported keyword warning: $(cat "$tmp/stderr")"
fi

[[ $fails -eq 0 ]]
