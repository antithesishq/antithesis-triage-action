#!/usr/bin/env bash
# Run the headless Claude Code triage session (plans/contract.md, "Agent invocation").
#
# Permission model (verified against Claude Code 2.1.312 with a fake Messages
# API): --permission-mode dontAsk denies every tool call that is not
# pre-approved, and --permission-prompts none tells the agent nobody can approve.
# What runs:
#   - Claude Code's built-in read-only Bash set: ls, cat, head, tail, grep, find
#     (no -exec/-delete), wc, sort, uniq, diff, date, and read-only git (log, show,
#     diff, rev-parse, cat-file, blame, grep, status). Its flag analysis rejects
#     write forms such as `git log --output=FILE`, so git gets no allow rule.
#   - The allow rules below: bare `snouty ...` (the shim enforces read-only
#     subcommands), `jq ...`, `<action>/scripts/att-checkout ...` (validates its
#     arguments; the only way to fetch or check out a commit), and exactly
#     `<action>/scripts/validate-findings.sh <out>/findings.json`.
#   - Read anywhere in the working directories (checkout, --add-dir dirs);
#     blockReadsOutsideWorkingDirectories makes reads elsewhere fail, including
#     `cat /proc/self/environ` and `ls ~`.
#   - Edit (which also creates files) and output redirects only to
#     <out>/findings.json, <out>/patches/, the scratch dir and the worktrees dir.
# What is denied: anything else, e.g. curl, interpreters, mkdir/rm/cp/mv,
# `git fetch`, `git worktree add`, heredocs, `$VAR` expansion, $(...) or
# backticks running non-allowlisted commands, `FOO=bar snouty` env prefixes,
# full-path binaries, `git -C`/`-c`, `&` backgrounding, redirects to other
# paths, and `cd` (explicit deny rule: without it, `cd <dir> && snouty ...` is
# approved because cd into a working dir counts as read-only).
# Residual gaps (accepted for v0.1; the API keys are in the agent's env anyway):
#   - `jq -n env` / `jq` on any path prints environment variables and files.
#   - Read-only commands inside $(...) in an allowed command can read files
#     outside the working dirs, e.g. `snouty runs list $(cat /etc/hostname)`.
#   - Command-text rules are not a sandbox; Claude Code's OS sandbox would be.
set -euo pipefail

: "${ATT_ACTION_PATH:?ATT_ACTION_PATH is not set}"
# shellcheck source=scripts/env.sh
. "$ATT_ACTION_PATH/scripts/env.sh"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"

one_line() { printf '%s' "$*" | tr '\r\n' '  '; }
fail() { echo "::error::$(one_line "$*")"; exit 2; }

model="${ATT_MODEL:-}"
max_turns="${ATT_MAX_TURNS:-200}"
max_budget="${ATT_MAX_BUDGET_USD:-10}"
timeout_min="${ATT_TIMEOUT_MINUTES:-60}"
[[ -n "$model" ]] || fail "model input is empty"
[[ "$max_turns" =~ ^[1-9][0-9]*$ ]] || fail "max-turns must be a positive integer, got '$max_turns'"
[[ "$max_budget" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "max-budget-usd must be a number, got '$max_budget'"
[[ "$timeout_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "timeout-minutes must be a number, got '$timeout_min'"

prompt="$ATT_WORK/prompt.md"
stream="$ATT_WORK/stream.jsonl"
result="$ATT_WORK/agent-result.json"
[[ -s "$prompt" ]] || fail "missing $prompt (render-prompt.sh must run first)"
[[ -d "$ATT_HOME/plugin" ]] || fail "triage skill plugin not found at $ATT_HOME/plugin"
command -v claude >/dev/null || fail "claude is not on PATH"

mkdir -p "$ATT_OUT/patches" "$ATT_HOME/worktrees" "$ATT_WORK/scratch"
# Permission rules match resolved paths, so use physical absolute paths.
out=$(cd "$ATT_OUT" && pwd -P)
worktrees=$(cd "$ATT_HOME/worktrees" && pwd -P)
scratch=$(cd "$ATT_WORK/scratch" && pwd -P)
plugin=$(cd "$ATT_HOME/plugin" && pwd -P)
scripts=$(cd "$ATT_ACTION_PATH/scripts" && pwd -P)
rm -f "$result"
: > "$stream"

sid=$(cat "$ATT_WORK/session-id" 2>/dev/null || true)
if ! [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  sid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr 'A-F' 'a-f')
  printf '%s\n' "$sid" > "$ATT_WORK/session-id"
fi

versions="$ATT_WORK/versions.json"
tmp=$(mktemp "$ATT_WORK/versions.XXXXXX")
if jq -e 'type == "object"' "$versions" >/dev/null 2>&1; then
  jq --arg model "$model" '.model = $model' "$versions" > "$tmp"
else
  jq -n --arg model "$model" '{model: $model}' > "$tmp"
fi
mv "$tmp" "$versions"

timeout_s=$(awk -v m="$timeout_min" 'BEGIN { printf "%d", m * 60 }')
deadline=$(date -u -d "@$(( $(date +%s) + timeout_s ))" +%Y-%m-%dT%H:%M:%SZ)
limits="Limits enforced by antithesis-triage-action for this session: at most $max_turns turns, about \$$max_budget of model spend, and a hard wall-clock deadline at $deadline (UTC), $timeout_min minutes after the start. The session is cut off without warning at any of these limits, so keep $out/findings.json current."

allowed=(
  "Bash(snouty *)"
  "Bash(jq *)"
  "Edit(/$out/findings.json)"
  "Edit(/$out/patches/**)"
  "Edit(/$scratch/**)"
  "Edit(/$worktrees/**)"
)
# Action-owned helpers, with the same command text render-prompt.sh puts in
# the prompt: att-checkout with any arguments (it validates them), and the
# validator only exactly as written (no *).
checkout_q=$(printf '%q' "$scripts/att-checkout")
validate_cmd="$(printf '%q' "$scripts/validate-findings.sh") $(printf '%q' "$out/findings.json")"
if [[ -x "$scripts/att-checkout" ]]; then
  allowed+=("Bash($checkout_q *)")
else
  echo "::warning::$scripts/att-checkout is missing; the agent cannot check out the commits runs tested."
fi
if [[ -x "$scripts/validate-findings.sh" ]]; then
  allowed+=("Bash($validate_cmd)")
  grep -qF -- "$validate_cmd" "$prompt" || echo "::warning::The prompt does not contain the validator command the agent is allowed to run: $validate_cmd"
else
  echo "::warning::$scripts/validate-findings.sh is missing; the agent cannot validate findings.json."
fi
settings='{"permissions":{"blockReadsOutsideWorkingDirectories":true},"disableAllHooks":true}'

# --bare: no hooks, CLAUDE.md, MCP or plugins from the checkout. It also limits
# the tools to Bash, Read and Edit whatever --tools says, so we ask for exactly
# those. --setting-sources user: don't read the checkout's .claude/settings*.json
# (bare mode still applies their env block and helper commands).
cmd=(claude -p --bare
  --plugin-dir "$plugin"
  --model "$model"
  --max-turns "$max_turns"
  --max-budget-usd "$max_budget"
  --output-format stream-json --verbose
  --session-id "$sid"
  --permission-mode dontAsk --permission-prompts none
  --setting-sources user
  --settings "$settings"
  --tools "Bash,Read,Edit"
  --allowedTools "${allowed[@]}"
  --disallowedTools "Bash(cd *)"
  --add-dir "$out" "$worktrees" "$scratch" "$plugin"
  --append-system-prompt "$limits")

echo "::group::Claude Code invocation"
printf '%q ' "${cmd[@]}"; echo
echo "::endgroup::"

# Progress in the Actions log: one line per tool call with the tool name, the
# program for Bash, and for snouty its subcommand, each mapped onto a fixed
# list. No arguments or other agent-chosen text, so the public log can't carry
# data (full snouty commands are in commands.log, redacted, in the artifact).
# shellcheck disable=SC2016 # jq program, not shell
progress='
  def tool: if IN("Bash", "Read", "Edit", "Write", "Grep", "Glob", "Skill") then . else "other tool" end;
  def program:
    if IN("snouty", "jq", "git", "ls", "cat", "head", "tail", "grep", "find", "wc", "sort", "uniq", "diff", "date", "echo") then .
    elif endswith("/att-checkout") then "att-checkout"
    elif endswith("/validate-findings.sh") then "validate-findings.sh"
    else "other" end;
  def snouty_sub:  # non-flag words after "snouty"
    map(select(startswith("-") | not)) as $w
    | if $w[0] == "runs" and ($w[1] // "" | IN("list", "show", "properties", "logs", "search", "events", "build-logs", "exec", "cancel", "wait")) then " runs \($w[1])"
      elif ($w[0] // "" | IN("doctor", "docs", "launch", "debug", "update", "login", "mcp", "help", "runs")) then " \($w[0])"
      elif ($w | length) == 0 then ""
      else " (other)" end;
  fromjson? // empty
  | if .type == "system" and .subtype == "init" then
      "[agent] session started: Claude Code \(.claude_code_version // "?"), model \(.model // "?"), tools \((.tools // []) | join(",")), plugins \([.plugins[]?.name] | join(","))",
      (if (.plugin_errors // [] | length) > 0 then "::warning::\(.plugin_errors | length) plugin load error(s); see the transcript" else empty end),
      (if ([.plugins[]?.name] | index("antithesis-skills")) == null then "::warning::The antithesis-skills plugin did not load" else empty end)
    elif .type == "system" and .subtype == "permission_denied" then
      "[agent]   denied: \(.tool_name // "?" | tostring | tool)"
    elif .type == "system" and .subtype == "api_retry" then
      "[agent] API retry \(.attempt // "?")/\(.max_retries // "?")"
    elif .type == "assistant" then
      .message.content[]? | select(.type == "tool_use")
      | if .name == "Bash" then
          ((.input.command // "") | tostring | [splits("\\s+")] | map(select(. != ""))) as $w
          | (if $w[0] == "timeout" then $w[2:] else $w end) as $w
          | ($w[0] // "" | program) as $p
          | if $p == "snouty" then "[agent] Bash: snouty\($w[1:] | snouty_sub)" else "[agent] Bash: \($p)" end
        else "[agent] \(.name // "?" | tostring | tool)" end
    elif .type == "result" then
      "[agent] finished: \(.subtype // "?"), \(.num_turns // "?") turns, $\((.total_cost_usd // 0) * 100 | round / 100), \(.permission_denials // [] | length) permission denials"
    else empty end
'

# Process lifetime. Claude runs in its own session (setsid), but its Bash tool
# starts every command in a further session of its own, so a session or group
# kill alone misses those. Every process the agent starts inherits
# ATT_AGENT_TOKEN, so after claude exits (for any reason, including this step
# being cancelled) we also kill whatever still carries the token. Nothing may
# keep writing into ATT_OUT once finalize starts.
agent_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
agent_pid=""
kill_agent_tree() {
  local sig=$1 env_file pid found
  if [[ -n "$agent_pid" ]]; then
    kill -"$sig" -- "-$agent_pid" 2>/dev/null || true
    pkill -"$sig" -s "$agent_pid" 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5; do
    found=0
    for env_file in /proc/[0-9]*/environ; do
      grep -qzxF "ATT_AGENT_TOKEN=$agent_token" "$env_file" 2>/dev/null || continue
      pid=${env_file#/proc/}; pid=${pid%/environ}
      kill -"$sig" "$pid" 2>/dev/null && found=1
    done
    [[ "$found" == 1 && "$sig" == KILL ]] || break
    sleep 0.2
  done
}
# shellcheck disable=SC2317 # invoked by trap
on_signal() {
  echo "::warning::Interrupted; stopping the agent."
  kill_agent_tree INT
  sleep 2
  kill_agent_tree KILL
  exit 130
}
trap on_signal INT TERM
trap 'kill_agent_tree KILL' EXIT

cd "$GITHUB_WORKSPACE"
env -u GITHUB_TOKEN -u GH_TOKEN -u ATT_GITHUB_TOKEN \
    -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_RUNTIME_URL -u ACTIONS_RESULTS_URL -u ACTIONS_CACHE_URL \
    -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_OUTPUT -u GITHUB_STATE -u GITHUB_STEP_SUMMARY \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 ATT_AGENT_TOKEN="$agent_token" \
  setsid timeout -s INT -k 120 "${timeout_min}m" "${cmd[@]}" < "$prompt" > "$stream" &
agent_pid=$!
tail -n +1 -f -s 1 --pid="$agent_pid" "$stream" | jq -R -r --unbuffered "$progress" &
progress_pid=$!
rc=0
wait "$agent_pid" || rc=$?
kill_agent_tree KILL
wait "$progress_pid" || echo "::warning::The progress printer failed; the stream is still in $stream"

# Last result line, if any (stream lines can be truncated if the process died).
jq -c -R 'fromjson? | select(type == "object" and .type == "result")' "$stream" | tail -n 1 > "$result.tmp" || true
if [[ -s "$result.tmp" ]]; then mv "$result.tmp" "$result"; else rm -f "$result.tmp"; fi

subtype=""; is_error="true"
if [[ -s "$result" ]]; then
  subtype=$(jq -r '.subtype // ""' "$result")
  is_error=$(jq -r '.is_error // false' "$result")
fi

if [[ "$rc" == 124 || "$rc" == 137 ]]; then
  echo "::error::The agent hit the ${timeout_min}-minute timeout and was stopped (exit $rc)."
  exit 124
fi
if [[ "$rc" == 0 && "$subtype" == success && "$is_error" != true ]]; then
  echo "::notice::Triage agent finished."
  exit 0
fi
case "$subtype" in
  error_max_turns) echo "::error::The agent stopped at the max-turns cap ($max_turns)." ;;
  error_max_budget_usd) echo "::error::The agent stopped at the max-budget-usd cap (\$$max_budget)." ;;
  "") echo "::error::Claude Code exited with $rc without a result." ;;
  *)
    # Claude Code's own error text (e.g. authentication); capped.
    detail=$(jq -r '[(.errors // [])[], (if .is_error then (.result // empty) else empty end)] | map(tostring) | join("; ")' "$result" 2>/dev/null || true)
    echo "::error::The agent failed (${subtype}, exit $rc): $(one_line "${detail:0:200}")"
    ;;
esac
(( rc != 0 )) && exit "$rc"
exit 1
