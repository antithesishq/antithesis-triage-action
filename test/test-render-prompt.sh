#!/usr/bin/env bash
# Tests for scripts/render-prompt.sh: hostile input text must come through
# verbatim, never be executed, and never be re-scanned for placeholders.
# shellcheck disable=SC2016 # literal $ and backticks are the point here
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { if [ "$1" -eq 0 ]; then echo "ok - $2"; else echo "not ok - $2"; failures=$((failures + 1)); fi; }

# render <action_path> [VAR=value ...]: run render-prompt.sh in a clean env.
render() {
  local action=$1; shift
  rm -rf "${tmp:?}/home"
  env -i PATH="$PATH" HOME="$tmp" ATT_ACTION_PATH="$action" ATT_HOME="$tmp/home" \
    ATT_OUT="$tmp/home/out" ATT_WORK="$tmp/home/work" \
    GITHUB_REPOSITORY=acme/widgets GITHUB_SHA=0123456789abcdef GITHUB_REF_NAME=main \
    GITHUB_WORKSPACE="$tmp/ws" GITHUB_EVENT_PATH="$tmp/event.json" "$@" \
    bash "$action/scripts/render-prompt.sh" > "$tmp/log" 2>&1
}
echo '{"repository":{"default_branch":"trunk"}}' > "$tmp/event.json"

nasty_runs='Runs with "double" and '\''single'\'' quotes, $HOME, $(touch '"$tmp"'/pwned1), `touch '"$tmp"'/pwned2`'
nasty_known=$'"Balance stays nonnegative": tracked in #123\n```\nbreak out of the fence?\n```\n{{SHA}} and {{IN_RUNS}} stay literal\n\\n backslash-n, tab:\there'
nasty_instr=$'::error::not a workflow command\n${ATT_OUT} %s %%'

render "$root" ATT_IN_RUNS="$nasty_runs" ATT_IN_KNOWN_ISSUES="$nasty_known" \
  ATT_IN_INSTRUCTIONS="$nasty_instr" ATT_IN_SINCE=7d ATT_IN_RUN_IDS=$'run-1\nrun-2' \
  ANTITHESIS_TENANT=acme
ok $? "renders with hostile inputs"
prompt="$tmp/home/work/prompt.md"
inputs="$tmp/home/work/inputs.json"

[ ! -e "$tmp/pwned1" ] && [ ! -e "$tmp/pwned2" ]; ok $? "no command substitution was executed"
[ "$(head -n 1 "$prompt")" = "/antithesis-skills:antithesis-triage" ]; ok $? "prompt starts with the skill invocation"

jq -e --arg r "$nasty_runs" --arg k "$nasty_known" --arg i "$nasty_instr" \
  '.runs == $r and ."known-issues" == $k and .instructions == $i and .since == "7d"
   and ."run-ids" == "run-1\nrun-2" and .grouping == "" and .ignore == ""
   and (keys == (["runs","since","limit","run-ids","run-params","grouping","known-issues","ignore","instructions"] | sort))' \
  "$inputs" > /dev/null
ok $? "inputs.json holds every input verbatim under the action's input names"

grep -qF -- "$nasty_runs" "$prompt"; ok $? "runs text appears verbatim in the prompt"
grep -qF -- '{{SHA}} and {{IN_RUNS}} stay literal' "$prompt"; ok $? "placeholders inside inputs are not expanded"
grep -qF -- 'tab:	here' "$prompt" && grep -qF -- '\n backslash-n' "$prompt"; ok $? "tabs and backslashes survive"
grep -qF -- '${ATT_OUT} %s %%' "$prompt"; ok $? "dollar and percent text survives"
grep -q '^````text$' "$prompt"; ok $? "fence grows past backtick runs in the input"
grep -qF '`acme` (from `ANTITHESIS_TENANT`)' "$prompt"; ok $? "tenant is rendered"
grep -qF 'default branch `trunk`' "$prompt"; ok $? "default branch comes from the event payload"
checkout="$(cd "$root/scripts" && pwd -P)/att-checkout"
grep -qF -- "\`$checkout <40-hex-sha> [patch-<slug>]\`" "$prompt" && grep -qF -- "\`$checkout <sha> patch-<slug>\`" "$prompt"
ok $? "att-checkout is rendered with its physical path"
! grep -qE 'git (fetch|worktree add)' "$prompt"; ok $? "the prompt no longer suggests git fetch or git worktree add"
grep -qF "\`$tmp/home/out/findings.json\`" "$prompt"; ok $? "ATT_OUT path is rendered"
grep -qF "$tmp/home/work/scratch" "$prompt" && [ -d "$tmp/home/work/scratch" ]; ok $? "scratch dir is rendered and created"
grep -qF '"schema_version":{"const":"0.1"}' "$prompt"; ok $? "schema is embedded"
validate="$(cd "$root/scripts" && pwd -P)/validate-findings.sh $(cd "$tmp/home/out" && pwd -P)/findings.json"
[ "$(grep -cxF -- "$validate" "$prompt")" -eq 1 ] && grep -qF -- "\`$validate\`" "$prompt"; ok $? "validator command is rendered with physical paths"
[ "$(grep -c '^(not set)$' "$prompt")" -eq 4 ]; ok $? "the four empty inputs render as (not set)"
# Only the two literal placeholders from the known-issues input may remain.
[ "$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$prompt" | wc -l)" -eq 2 ]; ok $? "no template placeholder is left"
grep -q '^::stop-commands::att-' "$tmp/log" && grep -q '^::endgroup::$' "$tmp/log"; ok $? "log output is wrapped in stop-commands"
token=$(sed -n 's/^::stop-commands::\(att-[0-9a-f]*\)$/\1/p' "$tmp/log")
awk -v t="::$token::" '/^::stop-commands::/ {on = 1} $0 == t {on = 0} /^::error::/ && !on {bad = 1} END {exit bad}' "$tmp/log" && grep -qx "::$token::" "$tmp/log"
ok $? "input lines that look like workflow commands are fenced by stop-commands"

echo '{"schedule":"0 7 * * *"}' > "$tmp/event.json"
render "$root" GITHUB_EVENT_NAME=schedule
grep -qF 'default branch `main`' "$prompt"; ok $? "scheduled runs use GITHUB_REF_NAME as the default branch"
render "$root" GITHUB_EVENT_NAME=workflow_dispatch
grep -qF 'default branch `unknown`' "$prompt"; ok $? "payload without .repository renders unknown"
[ "$(grep -c '^(not set)$' "$prompt")" -eq 9 ]; ok $? "renders with every input unset"
grep -qF 'not set in the environment; snouty resolves it' "$prompt"; ok $? "missing tenant falls back to snouty's configuration"

# A template with an unknown placeholder must fail loudly.
mkdir -p "$tmp/action/prompts" "$tmp/action/schema" "$tmp/action/scripts"
cp "$root/schema/findings.schema.json" "$tmp/action/schema/"
cp "$root/scripts/render-prompt.sh" "$root/scripts/env.sh" "$tmp/action/scripts/"
printf '/antithesis-skills:antithesis-triage\n{{REPOSITORY}} {{NO_SUCH_THING}}\n' > "$tmp/action/prompts/triage.md"
if render "$tmp/action"; then rc=1; else grep -q 'NO_SUCH_THING' "$tmp/log"; rc=$?; fi
ok "$rc" "unknown placeholder fails the render"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
