#!/usr/bin/env bash
# Tests for scripts/preflight.sh with a fake `snouty doctor`.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

# fake_doctor <json> <exit>
fake_doctor() {
  cat > "$tmp/snouty" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
$1
JSON
exit $2
EOF
  chmod +x "$tmp/snouty"
}

run() { # expected_exit description
  local out rc=0
  out=$(env -i PATH="$PATH" HOME="$tmp" ATT_HOME="$tmp" ATT_SNOUTY_REAL="$tmp/snouty" \
    GITHUB_ENV="$tmp/github_env" ANTITHESIS_API_KEY=k ANTITHESIS_TENANT=acme \
    ANTHROPIC_API_KEY=a bash "$script" 2>&1) || rc=$?
  if [ "$rc" -eq "$1" ]; then echo "ok - $2"; else echo "not ok - $2 (exit $rc)"; echo "$out" | sed 's/^/#   /'; failures=$((failures + 1)); fi
  printf '%s' "$out" > "$tmp/last-output"
}

check() { ok() { local w=ok; [ "$1" -eq 0 ] || { w="not ok"; failures=$((failures + 1)); }; echo "$w - $2"; }; grep -q -- "$1" "$2"; ok $? "$3"; }

fake_doctor '{"ok":true,"checks":[{"name":"api_key","status":"ok","message":"ok"}],"settings":{"tenant":"acme"}}' 0
run 0 "all checks pass"
check "ANTITHESIS_BASE_URL=https://acme.antithesis.com" "$tmp/github_env" "pins the API host in GITHUB_ENV"
check "SNOUTY_SETTINGS_PATH=$tmp/snouty-settings.toml" "$tmp/github_env" "points snouty at an empty settings file"

fake_doctor '{"ok":false,"checks":[{"name":"api_key","status":"ok","message":"ok"},{"name":"container_runtime","status":"error","message":"no docker"},{"name":"docker_compose","status":"error","message":"no compose"}],"settings":{}}' 1
run 0 "container runtime failures are ignored"
check "ignoring failed checks not needed for triage" "$tmp/last-output" "warns about ignored checks"

fake_doctor '{"ok":false,"checks":[{"name":"api_key","status":"error","message":"invalid key"}],"settings":{}}' 1
run 1 "api_key failure blocks"
check "invalid key" "$tmp/last-output" "names the failing check"

fake_doctor '{"ok":false,"checks":[{"name":"api_key","status":"ok","message":"ok"},{"name":"api_reachable","status":"error","message":"timeout"}],"settings":{}}' 1
run 1 "other failing checks block"

fake_doctor 'not json' 1
run 1 "garbage doctor output blocks"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
