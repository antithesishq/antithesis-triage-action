#!/usr/bin/env bash
# Run the headless Claude Code triage session (plans/contract.md, "Agent invocation").
#
# Permission model (verified against Claude Code 2.1.312; see the test notes in
# the v0.1 PR): --permission-mode dontAsk denies every tool call that is not
# pre-approved, and --permission-prompts none tells the agent nobody can approve.
# What runs:
#   - Claude Code's built-in read-only Bash set: ls, cat, head, tail, grep, find
#     (no -exec/-delete), wc, sort, uniq, diff, date, and read-only git (log, show,
#     diff, rev-parse, cat-file, blame, grep, status). Its flag analysis rejects
#     write forms such as `git log --output=FILE`, so git log/show/diff get no
#     explicit allow rule: a `Bash(git log *)` rule would approve --output.
#   - The allow rules below: bare `snouty ...` (the shim enforces read-only
#     subcommands), `jq ...`, `git worktree add ...`, `git fetch origin ...`,
#     and exactly `<action>/scripts/validate-findings.sh <out>/findings.json`.
#   - Read anywhere in the working directories (checkout, --add-dir dirs);
#     blockReadsOutsideWorkingDirectories makes reads elsewhere fail, including
#     `cat /proc/self/environ` and `ls ~`.
#   - Edit (which also creates files) and output redirects only under ATT_OUT,
#     the scratch dir and the worktrees dir.
# What is denied: anything else, e.g. curl, interpreters, mkdir/rm/cp/mv,
# heredocs, `$VAR` expansion, $(...) or backticks running non-allowlisted
# commands, `FOO=bar snouty` env prefixes, full-path binaries, `git -C`/`-c`,
# redirects to other paths, and `cd` (explicit deny rule: without it,
# `cd <dir> && snouty ...` is approved because cd into a working dir counts as
# read-only, and snouty would pick up a planted config from that dir).
# Residual gaps (accepted for v0.1; the API keys are in the agent's env anyway):
#   - `jq -n env` / `jq` on any path prints environment variables and files.
#   - Read-only commands inside $(...) in an allowed command can read files
#     outside the working dirs, e.g. `snouty runs list $(cat /etc/hostname)`.
#   - `git worktree add` accepts any target path, so it can create a new
#     directory of repository files anywhere the runner user can write.
#   - `git fetch origin` options (e.g. --upload-pack) are not filtered; they
#     have no effect with the https remote actions/checkout sets up.
#   - snouty runs with the checkout as its cwd; preflight pins its settings
#     file and API host in the environment, which the agent cannot change.
#   - Command-text rules are not a sandbox; Claude Code's OS sandbox would be.
set -euo pipefail

: "${ATT_HOME:?ATT_HOME is not set}" "${ATT_OUT:?ATT_OUT is not set}" "${ATT_WORK:?ATT_WORK is not set}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}" "${ATT_ACTION_PATH:?ATT_ACTION_PATH is not set}"

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
  "Bash(git worktree add *)"
  "Bash(git fetch origin *)"
  "Edit(/$out/**)"
  "Edit(/$scratch/**)"
  "Edit(/$worktrees/**)"
)
# Exact-match rule (no *): the findings validator on findings.json, nothing
# else. Must be the same text render-prompt.sh put in the prompt.
validator="$(cd "$ATT_ACTION_PATH/scripts" && pwd -P)/validate-findings.sh"
validate_cmd="$(printf '%q' "$validator") $(printf '%q' "$out/findings.json")"
if [[ -x "$validator" ]]; then
  allowed+=("Bash($validate_cmd)")
  grep -qF -- "$validate_cmd" "$prompt" || echo "::warning::The prompt does not contain the validator command the agent is allowed to run: $validate_cmd"
else
  echo "::warning::$validator is missing; the agent cannot validate findings.json."
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

# One line per tool call: the tool name, plus the command for snouty and git.
# Tool results and assistant text are never printed. Lines start with
# "[agent]", so nothing from the stream can act as a workflow command.
# shellcheck disable=SC2016 # jq program, not shell
progress='
  def oneline: gsub("[\\r\\n\\t]+"; " ") | gsub("\\?auth=[^\\s\"\\x27]*"; "") | sub("^ +"; "");
  def cut: if length > 300 then .[0:300] + " ..." else . end;
  fromjson? // empty
  | if .type == "system" and .subtype == "init" then
      "[agent] session started: Claude Code \(.claude_code_version // "?"), model \(.model // "?"), tools \((.tools // []) | join(",")), plugins \([.plugins[]?.name] | join(","))",
      (if (.plugin_errors // [] | length) > 0 then "::warning::Plugin load errors: \(.plugin_errors | tojson | oneline | cut)" else empty end),
      (if ([.plugins[]?.name] | index("antithesis-skills")) == null then "::warning::The antithesis-skills plugin did not load" else empty end)
    elif .type == "system" and .subtype == "permission_denied" then
      "[agent]   denied: \(.tool_name // "?")"
    elif .type == "system" and .subtype == "api_retry" then
      "[agent] API retry \(.attempt // "?")/\(.max_retries // "?") (\(.error // "?"))"
    elif .type == "assistant" then
      .message.content[]? | select(.type == "tool_use")
      | if .name == "Bash" then
          ((.input.command // "") | tostring | oneline) as $c
          | if ($c | test("^(timeout +[^ ]+ +)?(snouty|git)( |$)")) then "[agent] Bash: \($c | cut)"
            else "[agent] Bash (\($c | split(" ")[0] | split("/") | last | .[0:40]))" end
        else "[agent] \(.name)" end
    elif .type == "result" then
      "[agent] finished: \(.subtype // "?"), \(.num_turns // "?") turns, $\((.total_cost_usd // 0) * 100 | round / 100), \(.permission_denials // [] | length) permission denials"
    else empty end
'

cd "$GITHUB_WORKSPACE"
set +e
env -u GITHUB_TOKEN -u GH_TOKEN -u ATT_GITHUB_TOKEN -u ACTIONS_RUNTIME_TOKEN \
    -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_OUTPUT -u GITHUB_STATE -u GITHUB_STEP_SUMMARY \
  timeout -s INT -k 120 "${timeout_min}m" "${cmd[@]}" < "$prompt" \
  | tee -p "$stream" \
  | jq -R -r --unbuffered "$progress"
status=("${PIPESTATUS[@]}")
set -e
rc=${status[0]}
[[ "${status[2]}" == 0 ]] || echo "::warning::Progress printer exited with ${status[2]}; the stream is still in $stream"

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
    detail=$(jq -r '[(.errors // [])[], (if .is_error then (.result // empty) else empty end)] | map(tostring) | join("; ")' "$result" 2>/dev/null || true)
    echo "::error::The agent failed (${subtype}, exit $rc): $(one_line "${detail:0:500}")"
    ;;
esac
(( rc != 0 )) && exit "$rc"
exit 1
