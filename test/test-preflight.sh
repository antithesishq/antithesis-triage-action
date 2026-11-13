#!/usr/bin/env bash
# Tests for scripts/preflight.sh with a fake `snouty doctor` (snouty 0.10's
# --json report: checks have an id, status and message).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
script="$root/scripts/preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

# fake_doctor <json> <exit>: also records the environment doctor ran with.
fake_doctor() {
  cat > "$tmp/snouty" <<EOF
#!/usr/bin/env bash
printf 'ANTITHESIS_BASE_URL=%s\nSNOUTY_SETTINGS_PATH=%s\nARGS=%s\n' \
  "\${ANTITHESIS_BASE_URL:-}" "\${SNOUTY_SETTINGS_PATH:-}" "\$*" > "$tmp/doctor-env"
cat <<'JSON'
$1
JSON
exit $2
EOF
  chmod +x "$tmp/snouty"
}

# run <expected_exit> <description> [VAR=value ...]: extra assignments override
# the defaults; VAR= (empty) leaves a credential unset.
run() {
  local want=$1 desc=$2 out rc=0
  shift 2
  rm -f "$tmp/doctor-env"
  out=$(env -i PATH="$PATH" HOME="$tmp" RUNNER_TEMP="$tmp/runner" ATT_ACTION_PATH="$root" \
    ATT_HOME="$tmp" ATT_SNOUTY_REAL="$tmp/snouty" GITHUB_ENV="$tmp/github_env" \
    ANTITHESIS_API_KEY=k ANTITHESIS_TENANT=acme ANTHROPIC_API_KEY=a "$@" bash "$script" 2>&1) || rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok - $desc"; else
    echo "not ok - $desc (exit $rc)"; printf '#   %s\n' "${out//$'\n'/$'\n#   '}"; failures=$((failures + 1)); fi
  printf '%s' "$out" > "$tmp/last-output"
}

check() { # pattern file description
  if grep -q -- "$1" "$2" 2>/dev/null; then echo "ok - $3"; else
    echo "not ok - $3"; failures=$((failures + 1)); fi
}
check_not() { # pattern file description
  if grep -q -- "$1" "$2" 2>/dev/null; then echo "not ok - $3"; failures=$((failures + 1)); else
    echo "ok - $3"; fi
}

: > "$tmp/snouty-settings.toml" # install.sh creates it
creds_ok='{"id":"credentials","kind":"api_key","status":"ok","message":"API key provided"}'
api_ok='{"id":"api","status":"ok","message":"Antithesis API reachable"}'
ok_json='{"ok":true,"checks":['"$creds_ok,$api_ok"']}'

fake_doctor "$ok_json" 0
run 0 "all checks pass"
check "$(printf 'ok\tcredentials\tAPI key provided')" "$tmp/last-output" "prints each check by id"
check "^ANTITHESIS_BASE_URL=https://acme.antithesis.com$" "$tmp/doctor-env" "doctor runs with the API host pinned"
check "^SNOUTY_SETTINGS_PATH=$tmp/snouty-settings.toml$" "$tmp/doctor-env" "doctor runs with the empty settings file"
check "^ARGS=doctor --json$" "$tmp/doctor-env" "calls the real snouty doctor --json"
if [ -e "$tmp/github_env" ]; then echo "not ok - writes nothing to GITHUB_ENV"; failures=$((failures + 1))
else echo "ok - writes nothing to GITHUB_ENV"; fi

run 0 "an explicit ANTITHESIS_BASE_URL is kept" ANTITHESIS_BASE_URL=https://proxy.example
check "^ANTITHESIS_BASE_URL=https://proxy.example$" "$tmp/doctor-env" "doctor sees the explicit base URL"

fake_doctor '{"ok":false,"checks":[{"id":"container_runtime","status":"error","message":"no docker"},{"id":"docker_compose","status":"error","message":"no compose"},'"$creds_ok,$api_ok"',{"id":"repository","status":"warn","message":"repository is not set"}]}' 1
run 0 "container runtime failures and warnings are ignored"
check "ignoring failed checks not needed for triage: container_runtime, docker_compose" "$tmp/last-output" "warns about ignored checks"

fake_doctor '{"ok":false,"checks":[{"id":"credentials","kind":"api_key","status":"error","message":"the API key is empty","notes":[{"level":"note","text":"set ANTITHESIS_API_KEY"}]}]}' 1
run 1 "credentials failure blocks"
check "credentials: the API key is empty (set ANTITHESIS_API_KEY)" "$tmp/last-output" "names the failing check with its notes"
check "The credentials check is 'error'" "$tmp/last-output" "points at the credentials check"

fake_doctor '{"ok":false,"checks":['"$creds_ok"',{"id":"api","status":"error","message":"Antithesis API rejected authentication"}]}' 1
run 1 "other failing checks block"
check "api: Antithesis API rejected authentication" "$tmp/last-output" "names the failing API check"

# snouty before 0.10 named its checks (`name`, an `api_key` check) and printed
# the settings; install.sh refuses those versions, and preflight does not
# mistake such a report for a pass.
fake_doctor '{"ok":true,"checks":[{"name":"api_key","status":"ok","message":"ok"}],"settings":{"tenant":"acme"}}' 0
run 1 "a report without a credentials check blocks"
check "The credentials check is 'absent'" "$tmp/last-output" "says the credentials check is missing"

fake_doctor 'not json' 1
run 1 "garbage doctor output blocks"

fake_doctor "$ok_json" 0
run 1 "missing ANTITHESIS_API_KEY blocks" ANTITHESIS_API_KEY=
check "ANTITHESIS_API_KEY is not set" "$tmp/last-output" "says the API key is missing"
check_not "." "$tmp/doctor-env" "doctor not run without an API key"
run 1 "missing ANTITHESIS_TENANT blocks" ANTITHESIS_TENANT=
check "ANTITHESIS_TENANT is not set" "$tmp/last-output" "says the tenant is missing"
run 1 "no model credential blocks" ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=x
check "does not read OAuth credentials" "$tmp/last-output" "explains OAuth tokens don't work with --bare"
run 1 "CLAUDE_CODE_USE_BEDROCK=0 is not a credential" ANTHROPIC_API_KEY= CLAUDE_CODE_USE_BEDROCK=0
run 0 "Bedrock counts as a model credential" ANTHROPIC_API_KEY= CLAUDE_CODE_USE_BEDROCK=1
run 0 "Vertex counts as a model credential" ANTHROPIC_API_KEY= CLAUDE_CODE_USE_VERTEX=1
run 1 "missing snouty blocks" ATT_SNOUTY_REAL="$tmp/nope"
check "snouty is not installed" "$tmp/last-output" "says snouty is missing"
rm "$tmp/snouty-settings.toml"
run 1 "missing settings file blocks"
check "settings file" "$tmp/last-output" "says the settings file is missing"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
