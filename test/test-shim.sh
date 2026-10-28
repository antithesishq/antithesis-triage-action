#!/usr/bin/env bash
# Tests for shim/snouty, against a fake real snouty laid out like ATT_HOME:
#   $tmp/home/bin/snouty      (the shim)
#   $tmp/home/libexec/snouty  (fake: records its argv, prints signed URLs)
# check() evals its condition, so conditions are single-quoted on purpose and
# the variables they read look unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/bin" "$tmp/home/libexec"
cp "$root/shim/snouty" "$tmp/home/bin/snouty"
cat > "$tmp/home/libexec/snouty" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$FAKE_MARK"
case "${FAKE_MODE:-}" in
  big) seq 1 200000; exit "${FAKE_EXIT:-0}" ;;
  stream) echo first; while [ ! -e "$FAKE_GO" ]; do sleep 0.05; done; echo second; exit 0 ;;
  noeol) printf 'x?auth=TOK'; exit 0 ;;
esac
echo "ARGS:$(printf ' [%s]' "$@")"
echo 'url: "https://t.antithesis.com/report/abc/x.html?auth=v2.public.SECRET1"'
echo 'mid: https://t.antithesis.com/r?a=1&auth=SECRET2&b=2 (see [link](https://t.antithesis.com/y?auth=SECRET4))'
echo 'err: https://t.antithesis.com/r?auth=SECRET3&foo=1' >&2
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$tmp/home/bin/snouty" "$tmp/home/libexec/snouty"

shim="$tmp/home/bin/snouty"
export FAKE_MARK="$tmp/invoked"
export ATT_COMMANDS_LOG="$tmp/commands.log"
unset ATT_SNOUTY_REAL FAKE_MODE FAKE_EXIT

fails=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

run() { # run the shim; sets rc, out, err
  rm -f "$FAKE_MARK"
  rc=0
  "$shim" "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  out=$(cat "$tmp/out")
  err=$(cat "$tmp/err")
}

expect_allowed() {
  local desc="allowed: snouty $*"
  run "$@"
  if [ "$rc" -ne 0 ]; then fail "$desc (exit $rc: $err)"; return; fi
  if [ ! -e "$FAKE_MARK" ] || ! cmp -s "$FAKE_MARK" <(if [ $# -gt 0 ]; then printf '%s\0' "$@"; fi); then
    fail "$desc (real snouty not called with the same argv)"; return
  fi
  pass "$desc"
}

expect_denied() {
  local desc="denied: snouty $*"
  run "$@"
  if [ "$rc" -ne 126 ]; then fail "$desc (exit $rc, want 126)"; return; fi
  if [ -e "$FAKE_MARK" ]; then fail "$desc (real snouty was called)"; return; fi
  if [[ $err != *"read-only"* || $err != *"recommend one in the report"* ]]; then
    fail "$desc (stderr lacks the read-only explanation)"; return
  fi
  local want got
  want=$(if [ $# -gt 0 ]; then printf '%s\0' "$@"; fi |
    jq -cRs 'if . == "" then [] else split("\u0000")[:-1] end')
  got=$(tail -n 1 "$ATT_COMMANDS_LOG" | jq -c '[.argv, .exit, .denied]')
  if [ "$got" != "[$want,126,true]" ]; then
    fail "$desc (commands.log line: $got)"; return
  fi
  pass "$desc"
}

# --- Allowed commands, global flags anywhere. --------------------------------------
expect_allowed runs list
expect_allowed runs
expect_allowed --json runs list
expect_allowed runs --json list
expect_allowed runs list --json -n 50
expect_allowed --verbose --json runs --json properties R1 --failing
expect_allowed --profile prod runs show R1
expect_allowed --profile=prod runs list
expect_allowed runs --profile exec list
expect_allowed runs show exec
expect_allowed runs logs R1 -12345 3.5 --begin-vtime 1.0
expect_allowed runs search R1 'filter(ev => ev.x == "a b")' -n 10
expect_allowed runs events R1 -m needle
expect_allowed runs build-logs R1
expect_allowed doctor --json
expect_allowed docs search foo bar
expect_allowed docs --offline show product/x
expect_allowed version
expect_allowed --version
expect_allowed -V
expect_allowed --help
expect_allowed -h
expect_allowed help
expect_allowed help runs exec
expect_allowed help debug
expect_allowed launch --help
expect_allowed runs exec --help
expect_allowed --json runs exec -h
expect_allowed debug -h --json
expect_allowed runs help exec
expect_allowed runs --help
expect_allowed mcp --help
expect_allowed --help runs cancel

# --- Denied commands and argument tricks. --------------------------------------------
expect_denied launch
expect_denied launch --config ./antithesis --duration 30
expect_denied run --config x
expect_denied debug --run-id R --input-hash -1 --vtime 2.0
expect_denied runs exec R1 -5 10.0 'cat /etc/passwd'
expect_denied runs cancel R1
expect_denied runs wait R1
expect_denied runs property R1 P1
expect_denied runs stream R1
expect_denied runs usage
expect_denied update
expect_denied login
expect_denied mcp
expect_denied validate .
expect_denied completions bash
expect_denied frobnicate
expect_denied
expect_denied --json
expect_denied --json runs exec R1 -5 10.0
expect_denied runs --json exec R1 -5 10.0
expect_denied --json runs --json exec R1 -5 10.0
expect_denied --verbose runs --verbose cancel R1
expect_denied --profile runs exec R1 -5 10.0
expect_denied --profile=x runs wait R1
expect_denied --profile
expect_denied --settings evil.toml runs list
expect_denied --settings=evil.toml runs list
expect_denied runs list --settings evil.toml
expect_denied -- runs list
expect_denied runs -- exec R1 -5 10.0
expect_denied --json=true runs list
expect_denied --jso runs list
expect_denied -x runs list
expect_denied RUNS list
expect_denied launch --help --config x
expect_denied --help launch --config x
expect_denied runs exec --help R1 -5 10.0
expect_denied runs exec -- --help
expect_denied -hV launch

# --- Output: ?auth= stripped, streams separate, exit code preserved. ---------------------
run runs list
check "stdout keeps URL, drops ?auth=" '[[ $out == *"x.html\""* && $out != *SECRET* ]]'
check "?a=1&auth=X&b=2 becomes ?a=1&b=2" '[[ $out == *"r?a=1&b=2 "* ]]'
check "markdown link keeps closing paren" '[[ $out == *"(https://t.antithesis.com/y))"* ]]'
check "stderr ?auth=X&foo=1 becomes ?foo=1" '[[ $err == *"r?foo=1"* && $err != *SECRET* ]]'
check "stdout has no stderr text" '[[ $out != *"err:"* && $out != *"::group::"* ]]'
check "stderr has no stdout text" '[[ $err != *"ARGS:"* ]]'
check "group header first on stderr" '[[ $(head -n 1 "$tmp/err") == "::group::snouty runs list" ]]'
check "endgroup last on stderr" '[[ $(tail -n 1 "$tmp/err") == "::endgroup::" ]]'
check "exit code line on stderr" '[[ $err == *"snouty exit 0 ("*" ms)"* ]]'

FAKE_EXIT=3 run runs show R1
check "exit code 3 preserved" '[ "$rc" -eq 3 ]'
check "exit code 3 logged" '[[ $(tail -n 1 "$ATT_COMMANDS_LOG" | jq -r ".exit, .denied" | tr "\n" " ") == "3 false " ]]'
FAKE_EXIT=1 run runs list
check "exit code 1 preserved" '[ "$rc" -eq 1 ]'

FAKE_MODE=noeol run runs list
check "missing trailing newline preserved" 'cmp -s "$tmp/out" <(printf x)'

FAKE_MODE=big run runs logs R1 H1
check "large output passes through intact" '[ "$(wc -l < "$tmp/out")" -eq 200000 ] && [ "$(tail -n 1 "$tmp/out")" = 200000 ]'

rc=0
FAKE_MODE=big timeout 20 "$shim" runs logs R1 H1 2>/dev/null | head -n 1 > "$tmp/head" || rc=$?
check "closed stdout (| head) does not hang" '[ "$(cat "$tmp/head")" = 1 ]'

rm -f "$tmp/go" "$tmp/stream.out"
FAKE_MODE=stream FAKE_GO="$tmp/go" "$shim" runs logs R1 H1 > "$tmp/stream.out" 2>/dev/null &
pid=$!
saw=0
for _ in $(seq 1 100); do
  if grep -q first "$tmp/stream.out" 2>/dev/null; then saw=1; break; fi
  sleep 0.05
done
touch "$tmp/go"
wait "$pid"
check "output streams before the command exits" '[ "$saw" -eq 1 ] && grep -q second "$tmp/stream.out"'

# --- commands.log ------------------------------------------------------------------------
: > "$ATT_COMMANDS_LOG"
run runs search R1 $'multi\nline' -dash '' 'it'\''s'
run launch --duration 30
check "one log line per call" '[ "$(wc -l < "$ATT_COMMANDS_LOG")" -eq 2 ]'
check "log lines have the contract fields and types" \
  'jq -se "all(.[]; (keys == [\"argv\",\"denied\",\"duration_ms\",\"exit\",\"ts\"]) and (.ts | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\")) and (.argv | type == \"array\") and (.exit | type == \"number\") and (.duration_ms | type == \"number\" and . >= 0) and (.denied | type == \"boolean\"))" "$ATT_COMMANDS_LOG" >/dev/null'
check "argv logged exactly (newline, dash, empty, quote)" \
  '[[ $(head -n 1 "$ATT_COMMANDS_LOG" | jq -c .argv) == "[\"runs\",\"search\",\"R1\",\"multi\\nline\",\"-dash\",\"\",\"it'\''s\"]" ]]'
check "denied call logged with exit 126" \
  '[[ $(tail -n 1 "$ATT_COMMANDS_LOG" | jq -c "[.argv, .exit, .denied]") == "[[\"launch\",\"--duration\",\"30\"],126,true]" ]]'
run runs search R1 $'multi\nline'
check "group header stays on one line" '[ "$(grep -c "^::group::" "$tmp/err")" -eq 1 ] && [[ $(head -n 1 "$tmp/err") == *"\$'"'"'multi\\nline'"'"'"* ]]'

# --- Locating the real binary. -------------------------------------------------------------
ATT_SNOUTY_REAL=/bin/false run runs list
check "libexec next to the shim wins over ATT_SNOUTY_REAL" '[ "$rc" -eq 0 ] && [ -e "$FAKE_MARK" ]'
mkdir -p "$tmp/lonely"
cp "$root/shim/snouty" "$tmp/lonely/snouty"
rc=0; ATT_SNOUTY_REAL="$tmp/home/libexec/snouty" "$tmp/lonely/snouty" runs list > /dev/null 2>&1 || rc=$?
check "falls back to ATT_SNOUTY_REAL outside the layout" '[ "$rc" -eq 0 ]'
rc=0; env -u ATT_SNOUTY_REAL "$tmp/lonely/snouty" runs list > /dev/null 2>&1 || rc=$?
check "missing real binary exits 127" '[ "$rc" -eq 127 ]'
rc=0; env -u ATT_COMMANDS_LOG "$shim" runs list > /dev/null 2>&1 || rc=$?
check "works without ATT_COMMANDS_LOG" '[ "$rc" -eq 0 ]'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
