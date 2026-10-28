#!/usr/bin/env bash
# Render prompts/triage.md into $ATT_WORK/prompt.md and record the action
# inputs in $ATT_WORK/inputs.json.
#
# Inputs can hold any text (quotes, $, backticks, newlines, {{...}}). They only
# ever reach jq as data (--arg / --rawfile), and placeholders are replaced in a
# single gsub pass, so nothing is evaluated by the shell and inserted text is
# never re-scanned for placeholders.
set -euo pipefail

: "${ATT_ACTION_PATH:?ATT_ACTION_PATH is not set; the install step must run first}"
: "${ATT_HOME:?ATT_HOME is not set}" "${ATT_OUT:?ATT_OUT is not set}" "${ATT_WORK:?ATT_WORK is not set}"

template="$ATT_ACTION_PATH/prompts/triage.md"
schema="$ATT_ACTION_PATH/schema/findings.schema.json"
scratch="$ATT_WORK/scratch"
worktrees="$ATT_HOME/worktrees"
mkdir -p "$ATT_WORK" "$ATT_OUT" "$scratch" "$worktrees"

# The agent may run exactly this command (run-agent.sh builds the identical
# exact-match allow rule), so use physical paths, shell-quoted.
validate_cmd="$(printf '%q' "$(cd "$ATT_ACTION_PATH/scripts" && pwd -P)/validate-findings.sh") $(printf '%q' "$(cd "$ATT_OUT" && pwd -P)/findings.json")"

# Keys match the action's input names.
jq -n \
  --arg runs "${ATT_IN_RUNS-}" \
  --arg since "${ATT_IN_SINCE-}" \
  --arg limit "${ATT_IN_LIMIT-}" \
  --arg run_ids "${ATT_IN_RUN_IDS-}" \
  --arg run_params "${ATT_IN_RUN_PARAMS-}" \
  --arg grouping "${ATT_IN_GROUPING-}" \
  --arg known_issues "${ATT_IN_KNOWN_ISSUES-}" \
  --arg ignore "${ATT_IN_IGNORE-}" \
  --arg instructions "${ATT_IN_INSTRUCTIONS-}" \
  '{runs: $runs, since: $since, limit: $limit, "run-ids": $run_ids,
    "run-params": $run_params, grouping: $grouping, "known-issues": $known_issues,
    ignore: $ignore, instructions: $instructions}' \
  > "$ATT_WORK/inputs.json"

default_branch=""
if [[ -n "${GITHUB_EVENT_PATH-}" && -r "${GITHUB_EVENT_PATH}" ]]; then
  default_branch=$(jq -r '.repository.default_branch // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
fi

# shellcheck disable=SC2016 # jq program, not shell
render='
  def fence:  # fenced block longer than any backtick run inside the value
    ([scan("`+") | length] | max // 0) as $n
    | ("`" * ([3, $n + 1] | max)) as $f
    | "\($f)text\n\(.)\n\($f)";
  def block:
    if test("\\S") then sub("\\A(\\s*\\n)+"; "") | sub("\\s+\\z"; "") | fence
    else "(not set)" end;
  def tenant:
    if test("^[A-Za-z0-9._-]+$") then "`\(.)` (from `ANTITHESIS_TENANT`)"
    elif test("\\S") then "\(tojson) (from `ANTITHESIS_TENANT`)"
    else "not set in the environment; snouty resolves it from its own configuration (see `settings` in `snouty doctor --json`)" end;
  $inputs[0] as $in
  | {
      REPOSITORY: $repository, SHA: $sha, REF_NAME: $ref_name,
      DEFAULT_BRANCH: $default_branch, WORKSPACE: $workspace,
      ATT_OUT: $out, SCRATCH: $scratch, WORKTREES: $worktrees, NOW: $now,
      TENANT: ($tenant | tenant), VALIDATE: $validate,
      SCHEMA: ($schema | fromjson | tojson),
      IN_RUNS: ($in.runs | block),
      IN_SINCE: ($in.since | block),
      IN_LIMIT: ($in.limit | block),
      IN_RUN_IDS: ($in."run-ids" | block),
      IN_RUN_PARAMS: ($in."run-params" | block),
      IN_GROUPING: ($in.grouping | block),
      IN_KNOWN_ISSUES: ($in."known-issues" | block),
      IN_IGNORE: ($in.ignore | block),
      IN_INSTRUCTIONS: ($in.instructions | block)
    } as $v
  | ([$tpl | scan("\\{\\{([A-Z0-9_]+)\\}\\}") | .[0]] | unique - ($v | keys)) as $unknown
  | if ($unknown | length) > 0
    then error("unknown placeholders in template: \($unknown | join(", "))")
    else $tpl | gsub("\\{\\{(?<k>[A-Z0-9_]+)\\}\\}"; $v[.k])
    end
'

tmp="$ATT_WORK/prompt.md.tmp"
jq -n -r \
  --rawfile tpl "$template" \
  --rawfile schema "$schema" \
  --slurpfile inputs "$ATT_WORK/inputs.json" \
  --arg repository "${GITHUB_REPOSITORY:-unknown}" \
  --arg sha "${GITHUB_SHA:-unknown}" \
  --arg ref_name "${GITHUB_REF_NAME:-unknown}" \
  --arg default_branch "${default_branch:-unknown}" \
  --arg workspace "${GITHUB_WORKSPACE:-$PWD}" \
  --arg tenant "${ANTITHESIS_TENANT-}" \
  --arg out "$ATT_OUT" \
  --arg scratch "$scratch" \
  --arg worktrees "$worktrees" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg validate "$validate_cmd" \
  "$render" > "$tmp"
mv "$tmp" "$ATT_WORK/prompt.md"

# Show the prompt in the log. stop-commands keeps input text that happens to
# look like a workflow command (::...::) from being interpreted by the runner.
token="att-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
echo "::group::Rendered prompt ($(wc -c < "$ATT_WORK/prompt.md") bytes)"
echo "::stop-commands::$token"
cat "$ATT_WORK/prompt.md"
echo "::$token::"
echo "::endgroup::"
