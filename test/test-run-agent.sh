#!/usr/bin/env bash
# Tests for scripts/run-agent.sh with a fake `claude` on PATH.
# shellcheck disable=SC2016 # literal $ in single quotes is intended
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/run-agent.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { if [ "$1" -eq 0 ]; then echo "ok - $2"; else echo "not ok - $2"; failures=$((failures + 1)); fi; }
has() { grep -qF -- "$1" "$2"; ok $? "$3"; }
lacks() { ! grep -qF -- "$1" "$2"; ok $? "$3"; }

mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/action/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/action/scripts/validate-findings.sh"
cp "$here/../scripts/env.sh" "$here/../scripts/att-checkout" "$tmp/action/scripts/"
chmod +x "$tmp/action/scripts/validate-findings.sh"
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Fake Claude Code: records how it was called, then plays a scenario.
printf '%s\n' "$@" > "$FAKE_DIR/args"
cat > "$FAKE_DIR/stdin"
env > "$FAKE_DIR/env"
pwd > "$FAKE_DIR/cwd"
init='{"type":"system","subtype":"init","claude_code_version":"9.9.9","model":"claude-test","tools":["Bash","Edit","Read"],"plugins":[{"name":"antithesis-skills","path":"/x"}]}'
case "$FAKE_CLAUDE_MODE" in
  success)
    echo "$init"
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"ASSISTANT-TEXT-NOT-SHOWN"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"snouty runs --json list -n 200"}}]}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"TOOL-OUTPUT-SECRET"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"jq -r JQ-FILTER-NOT-SHOWN /x"}},{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/x/findings.json"}}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"timeout 600 snouty runs show https://t.antithesis.com/report/x.html?auth=SIGNED-AUTH\nsecond line"}}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t6","name":"Bash","input":{"command":"COVERT-PROGRAM-NAME arg"}},{"type":"tool_use","id":"t7","name":"COVERT-TOOL-NAME","input":{}},{"type":"tool_use","id":"t8","name":"Bash","input":{"command":"snouty COVERT-SUBCOMMAND"}},{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"/x/scripts/att-checkout 0123 COVERT-ARG"}}]}}'
    # Leftovers that must not outlive the step: a plain background job and one
    # in its own session (like the Bash tool's commands).
    sleep 300 >/dev/null 2>&1 < /dev/null & echo $! > "$FAKE_DIR/bg1"
    setsid sleep 300 >/dev/null 2>&1 < /dev/null & echo $! > "$FAKE_DIR/bg2"
    echo '{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"t5","message":"denied"}'
    echo 'not json at all'
    echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.1234,"permission_denials":[{}],"result":"FINAL-TEXT"}'
    exit 0 ;;
  max_turns)
    echo "$init"
    echo '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":8,"errors":["Reached maximum number of turns (7)"]}'
    exit 1 ;;
  auth_error)
    echo "$init"
    echo '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"Invalid API key"}'
    exit 1 ;;
  hang)
    trap 'echo "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}"; kill "$pid" 2>/dev/null; exit 130' INT
    echo "$init"
    sleep 30 >/dev/null 2>&1 & pid=$!
    wait "$pid" ;;
  no_result)
    echo "$init"
    exit 3 ;;
esac
EOF
chmod +x "$tmp/bin/claude"

# run_agent <mode> [VAR=value ...]: fresh ATT_HOME, then run-agent.sh in a clean env.
run_agent() {
  local mode=$1; shift
  rm -rf "${tmp:?}/home" "$tmp/fake"/*
  mkdir -p "$tmp/home/plugin/skills/antithesis-triage" "$tmp/home/work" "$tmp/ws"
  printf '/antithesis-skills:antithesis-triage\nPROMPT-BODY "quoted" $(not run)\n' > "$tmp/home/work/prompt.md"
  echo '{"action_ref":"v0","snouty":"0.8.0","claude_code":"2.1.312","skills_ref":"abc"}' > "$tmp/home/work/versions.json"
  rc=0
  env -i PATH="$tmp/bin:$PATH" HOME="$tmp" FAKE_DIR="$tmp/fake" FAKE_CLAUDE_MODE="$mode" \
    ATT_ACTION_PATH="$tmp/action" ATT_HOME="$tmp/home" ATT_OUT="$tmp/home/out" ATT_WORK="$tmp/home/work" GITHUB_WORKSPACE="$tmp/ws" \
    ATT_MODEL=claude-test ATT_MAX_TURNS=7 ATT_MAX_BUDGET_USD=1.5 ATT_TIMEOUT_MINUTES=5 \
    GITHUB_TOKEN=ghs_not_for_the_agent GITHUB_ENV="$tmp/github_env" ANTITHESIS_API_KEY=kept \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=idtok ACTIONS_ID_TOKEN_REQUEST_URL=https://id ACTIONS_RUNTIME_URL=https://rt \
    ACTIONS_RESULTS_URL=https://res ACTIONS_CACHE_URL=https://cache ACTIONS_RUNTIME_TOKEN=rttok \
    "$@" bash "$script" > "$tmp/out" 2>&1 || rc=$?
}
work="$tmp/home/work"

run_agent success
ok "$rc" "success exits 0"
args="$tmp/fake/args"
for flag in -p --bare --verbose "--permission-prompts" none --setting-sources user \
            --tools Bash,Read,Edit --disallowedTools "Bash(cd *)" "Bash(snouty *)" "Bash(jq *)" \
            "Bash($tmp/action/scripts/att-checkout *)" "Edit(/$tmp/home/out/findings.json)" \
            "Edit(/$tmp/home/out/patches/**)" "Edit(/$tmp/home/work/scratch/**)" "Edit(/$tmp/home/worktrees/**)"; do
  grep -qxF -- "$flag" "$args"; ok $? "passes $flag"
done
! grep -qE '^Bash\(git |^Edit\(/'"$tmp"'/home/out/\*\*\)$' "$args"; ok $? "no git rules and no Edit rule for all of ATT_OUT"
[ "$(grep -c '^Edit(' "$args")" -eq 4 ]; ok $? "exactly four Edit rules"
grep -A1 -xF -- --permission-mode "$args" | grep -qxF dontAsk; ok $? "permission mode is dontAsk"
grep -qxF -- "Bash($tmp/action/scripts/validate-findings.sh $tmp/home/out/findings.json)" "$args"; ok $? "allows exactly the validator on findings.json"
[ "$(grep -c 'validate-findings' "$args")" -eq 1 ]; ok $? "no other rule mentions the validator"
has "::warning::The prompt does not contain the validator command" "$tmp/out" "warns when the prompt lacks the validator command"
grep -A1 -xF -- --max-turns "$args" | grep -qxF 7; ok $? "passes --max-turns from ATT_MAX_TURNS"
grep -A1 -xF -- --max-budget-usd "$args" | grep -qxF 1.5; ok $? "passes --max-budget-usd"
grep -A1 -xF -- --model "$args" | grep -qxF claude-test; ok $? "passes --model"
grep -A1 -xF -- --output-format "$args" | grep -qxF stream-json; ok $? "asks for stream-json"
grep -A1 -xF -- --plugin-dir "$args" | grep -qxF "$tmp/home/plugin"; ok $? "loads the plugin dir"
grep -A4 -xF -- --add-dir "$args" | grep -qxF "$tmp/home/worktrees"; ok $? "adds the worktrees dir"
grep -qF 'at most 7 turns' "$args"; ok $? "appends the limits to the system prompt"
sid=$(cat "$work/session-id")
[[ "$sid" =~ ^[0-9a-f-]{36}$ ]] && grep -A1 -xF -- --session-id "$args" | grep -qxF "$sid"; ok $? "session id is generated, saved and passed"
cmp -s "$tmp/fake/stdin" "$work/prompt.md"; ok $? "prompt arrives on stdin, untouched"
[ "$(cat "$tmp/fake/cwd")" = "$tmp/ws" ]; ok $? "runs in GITHUB_WORKSPACE"
lacks GITHUB_TOKEN= "$tmp/fake/env" "GITHUB_TOKEN is not passed to the agent"
lacks GITHUB_ENV= "$tmp/fake/env" "GITHUB_ENV is not passed to the agent"
for v in ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_URL ACTIONS_RESULTS_URL ACTIONS_CACHE_URL ACTIONS_RUNTIME_TOKEN; do
  lacks "$v=" "$tmp/fake/env" "$v is not passed to the agent"
done
has GIT_CONFIG_GLOBAL=/dev/null "$tmp/fake/env" "global git config is disabled for the agent"
has GIT_CONFIG_NOSYSTEM=1 "$tmp/fake/env" "system git config is disabled for the agent"
for f in bg1 bg2; do
  pid=$(cat "$tmp/fake/$f"); ! kill -0 "$pid" 2>/dev/null; ok $? "agent leftover $f is killed when claude exits"
done
has ANTITHESIS_API_KEY=kept "$tmp/fake/env" "other env is passed through"
[ "$(wc -l < "$work/stream.jsonl")" -eq 9 ]; ok $? "stream.jsonl captures every line"
jq -e '.type == "result" and .subtype == "success"' "$work/agent-result.json" > /dev/null; ok $? "agent-result.json holds the result line"
jq -e '.model == "claude-test" and .snouty == "0.8.0"' "$work/versions.json" > /dev/null; ok $? "versions.json gains model, keeps the rest"
[ -d "$tmp/home/out/patches" ] && [ -d "$work/scratch" ]; ok $? "creates patches and scratch dirs"
has "[agent] session started: Claude Code 9.9.9, model claude-test" "$tmp/out" "prints the session start"
has "[agent] Bash: snouty runs list" "$tmp/out" "prints the snouty subcommand"
lacks "-n 200" "$tmp/out" "never prints snouty arguments"
has "[agent] Bash: snouty runs show" "$tmp/out" "skips a leading timeout"
has "[agent] Bash: jq" "$tmp/out" "prints only the program name for other commands"
has "[agent] Edit" "$tmp/out" "prints known tool names"
has "[agent]   denied: Bash" "$tmp/out" "prints permission denials"
has "[agent] Bash: other" "$tmp/out" "unknown programs print as other"
has "[agent] other tool" "$tmp/out" "unknown tool names print as other tool"
has "[agent] Bash: snouty (other)" "$tmp/out" "unknown snouty subcommands print as (other)"
has "[agent] Bash: att-checkout" "$tmp/out" "att-checkout prints without arguments"
lacks COVERT "$tmp/out" "no agent-chosen text reaches the log"
lacks report/x.html "$tmp/out" "never prints URLs"
lacks SIGNED-AUTH "$tmp/out" "never prints signed auth tokens"
lacks TOOL-OUTPUT-SECRET "$tmp/out" "never prints tool output"
lacks JQ-FILTER-NOT-SHOWN "$tmp/out" "never prints non-snouty/git commands"
lacks ASSISTANT-TEXT-NOT-SHOWN "$tmp/out" "never prints assistant text"
lacks FINAL-TEXT "$tmp/out" "never prints the final result text"
has '[agent] finished: success, 4 turns, $0.12, 1 permission denials' "$tmp/out" "prints a result summary"

run_agent max_turns
[ "$rc" -ne 0 ]; ok $? "max-turns cap exits non-zero (got $rc)"
jq -e '.subtype == "error_max_turns"' "$work/agent-result.json" > /dev/null; ok $? "max-turns result is saved"
has "::error::The agent stopped at the max-turns cap (7)." "$tmp/out" "explains the max-turns cap"

run_agent auth_error
[ "$rc" -ne 0 ]; ok $? "is_error result exits non-zero"
has "Invalid API key" "$tmp/out" "shows the error text of a failed run"

run_agent hang ATT_TIMEOUT_MINUTES=0.03
[ "$rc" -eq 124 ]; ok $? "timeout exits 124 (got $rc)"
has "timeout and was stopped" "$tmp/out" "explains the timeout"
jq -e '.subtype == "error_during_execution"' "$work/agent-result.json" > /dev/null; ok $? "SIGINT result line is saved"

run_agent no_result
[ "$rc" -eq 3 ]; ok $? "exit code of claude is kept when there is no result (got $rc)"
[ ! -e "$work/agent-result.json" ]; ok $? "no agent-result.json without a result line"
has "without a result" "$tmp/out" "explains the missing result"

run_agent success ATT_MAX_TURNS=abc
[ "$rc" -eq 2 ] && [ ! -e "$tmp/fake/args" ]; ok $? "invalid max-turns fails before starting claude"
run_agent success ATT_TIMEOUT_MINUTES='5; rm -rf /'
[ "$rc" -eq 2 ] && [ ! -e "$tmp/fake/args" ]; ok $? "invalid timeout fails before starting claude"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
