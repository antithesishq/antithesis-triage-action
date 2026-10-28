#!/usr/bin/env bash
# End-to-end test: runs the action's step scripts chained together, in the
# order action.yml lists them, against a simulated GitHub runner. Each step
# runs the way the runner runs a composite `run:` step: a fresh
# `bash --noprofile --norc -eo pipefail` in the workspace, with the job's
# environment (GITHUB_*, RUNNER_TEMP, the caller's step env with the secrets)
# plus that step's `env:` from action.yml. The test checks that it passes
# exactly the env names action.yml passes, and honours `if: always()`.
#
# Simulated runner (one per scenario, laid out like a hosted runner):
#   work/_temp                      RUNNER_TEMP, with file-command files and
#                                   _github_workflow/event.json (schedule)
#   work/_actions/antithesishq/antithesis-triage-action/v0
#                                   copy of the action (ATT_ACTION_PATH)
#   work/bank/bank                  GITHUB_WORKSPACE, a 3-commit git repo
#
# install.sh runs for real, with a fake curl (test/fixtures/e2e/curl) on PATH
# for that step only, serving fake release downloads built here: snouty
# (fixtures/e2e/snouty, a fake API), Claude Code (fixtures/e2e/claude, a fake
# CLI that takes its paths from the prompt and runs real tool calls through
# the shim) and a skills tarball. The versions are not the pinned defaults, so
# install.sh takes their checksums from the fake server. No network.
#
# Scenarios:
#   success    the agent triages one run, writes a new failure with a
#              recommended debugging session and a patch, echoes the API key
#              into a tool result and findings.json, keeps a signed ?auth=
#              link, and runs one `snouty launch` that the shim refuses.
#   max_turns  the agent stops at the turn cap after writing an in_progress
#              findings.json.
#
# E2E_KEEP=1 keeps the temp directory for inspection.
# shellcheck disable=SC2016 # jq programs, bash -c scripts and literal backticks
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fx=$root/test/fixtures/e2e
tmp=$(mktemp -d)
if [ -n "${E2E_KEEP:-}" ]; then
  trap 'echo "# kept $tmp"' EXIT
else
  trap 'rm -rf "$tmp"' EXIT
fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # the test's own git calls
fails=0
declare -A step_rc=()

# Fake secrets: none of them match a token pattern, so only the exact-value
# redaction of the environment variables can remove them.
antithesis_key=e2e-antithesis-key-7f3a9c1d5b
anthropic_key=e2e-anthropic-key-2b8e6f0a4c
github_token=ghs_e2eFakeGithubToken0123456789abcd
secrets=("$antithesis_key" "$anthropic_key" "$github_token" "auth=SECRET")
run_id=e2e0c0ffee0000000000000000000000-7-1

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { # name command...
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}
has() { # file text name
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else not_ok "$3"; fi
}
lacks() { # file text name
  if grep -qF -- "$2" "$1" 2>/dev/null; then not_ok "$3"; else ok "$3"; fi
}
indent() { sed 's/^/#   /' "$@" 2>/dev/null || true; }
no_secrets() { # name path...
  local name=$1 s hits
  shift
  for s in "${secrets[@]}"; do
    hits=$(grep -rlF -- "$s" "$@" 2>/dev/null)
    if [ -n "$hits" ]; then
      not_ok "$name ('$s' found in: ${hits//$'\n'/, })"
      return
    fi
  done
  ok "$name"
}
output() { sed -n "s/^$2=//p" "$cmds/set_output_$1" 2>/dev/null; } # step name

# --- action.yml ---------------------------------------------------------------
# One line per `run:` step: script|`if:` condition|env names.
action_steps() {
  awk '
    function flush() {
      if (script != "") printf "%s|%s|%s\n", script, cond, substr(keys, 2)
      script = cond = keys = ""; inenv = 0
    }
    /^    - / { flush() }
    /^      env:[[:space:]]*$/ { inenv = 1; next }
    /^      [a-z-]+:/ { inenv = 0 }
    inenv && /^        [A-Za-z_][A-Za-z0-9_]*:/ { k = $1; sub(/:$/, "", k); keys = keys " " k }
    /^      if: / { cond = substr($0, 11) }
    /^      run: / && match($0, /scripts\/[A-Za-z0-9_.-]+/) { script = substr($0, RSTART + 8, RLENGTH - 8) }
    END { flush() }
  ' "$root/action.yml"
}
input_default() { # input name -> its default in action.yml, unquoted
  awk -v name="$1" '
    /^[^ ]/ { ins = ($0 == "inputs:"); next }
    ins && /^  [^ ]/ { cur = ($0 == "  " name ":"); next }
    ins && cur && /^    default:/ {
      v = $0; sub(/^    default:[ ]*/, "", v)
      if (v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }
  ' "$root/action.yml"
}

snouty_version=$("$fx/snouty" --version) && snouty_version=${snouty_version##* }
cc_version=$("$fx/claude" --version) && cc_version=${cc_version%% *}
skills_ref=$(input_default skills-ref)
model=$(input_default model)
artifact_name=$(input_default artifact-name)
artifact_name=${artifact_name//'${{ github.job }}'/triage}
artifact_name=${artifact_name//'${{ github.run_attempt }}'/1}

# --- fake release downloads -----------------------------------------------------
srv=$tmp/downloads
build_downloads() {
  local pkg=$tmp/pkg t p d sum top=antithesis-skills-$skills_ref
  d=$srv/github.com/antithesishq/snouty/releases/download/v$snouty_version
  mkdir -p "$d"
  for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    mkdir -p "$pkg/snouty-$t"
    install -m 0755 "$fx/snouty" "$pkg/snouty-$t/snouty"
    tar -cJf "$d/snouty-$t.tar.xz" -C "$pkg" "snouty-$t"
    (cd "$d" && sha256sum "snouty-$t.tar.xz" > "snouty-$t.tar.xz.sha256")
  done
  d=$srv/downloads.claude.ai/claude-code-releases/$cc_version
  sum=$(sha256sum "$fx/claude" | cut -d' ' -f1)
  for p in linux-x64 linux-arm64 linux-x64-musl linux-arm64-musl; do
    mkdir -p "$d/$p"
    install -m 0755 "$fx/claude" "$d/$p/claude"
  done
  jq -n --arg v "$cc_version" --arg s "$sum" '{version: $v, platforms: (
    [("linux-x64", "linux-arm64", "linux-x64-musl", "linux-arm64-musl") | {key: ., value: {checksum: $s}}]
    | from_entries)}' > "$d/manifest.json"
  mkdir -p "$pkg/$top/antithesis-triage/references" "$pkg/$top/antithesis-launch"
  printf -- '---\nname: antithesis-triage\ndescription: e2e stub\n---\n# Antithesis triage (stub)\n' \
    > "$pkg/$top/antithesis-triage/SKILL.md"
  echo stub > "$pkg/$top/antithesis-triage/references/logs.md"
  echo 'must not be installed' > "$pkg/$top/antithesis-launch/SKILL.md"
  mkdir -p "$srv/codeload.github.com/antithesishq/antithesis-skills/tar.gz" "$tmp/curlbin"
  tar -czf "$srv/codeload.github.com/antithesishq/antithesis-skills/tar.gz/$skills_ref" -C "$pkg" "$top"
  install -m 0755 "$fx/curl" "$tmp/curlbin/curl"
}
build_downloads

# --- one simulated workflow run ---------------------------------------------------
g() { git -C "$ws" -c user.name=e2e -c user.email=e2e@example.invalid "$@"; }
make_repo() {
  git -c init.defaultBranch=main init -q "$ws"
  mkdir -p "$ws/src"
  cat > "$ws/src/ledger.rs" <<'EOF'
pub struct Ledger { accounts_lock: Mutex<()> }

impl Ledger {
    pub fn transfer(&self, from: &Account, to: &Account, amount: i64) {
        let _guard = self.accounts_lock.lock();
        if from.balance() >= amount {
            from.withdraw(amount);
            to.deposit(amount);
        }
    }
}
EOF
  g add -A && g commit -qm "Add ledger"
  sed -i '/let _guard/d' "$ws/src/ledger.rs"
  g commit -qam "Use per-account locks"
  run_commit=$(g rev-parse HEAD)
  echo '# bank' > "$ws/README.md"
  g add README.md && g commit -qm "Add README"
  head_sha=$(g rev-parse HEAD)
}

# step_env <script>: senv=(NAME=value ...), the step's env as action.yml
# passes it (inputs at their action.yml defaults unless the scenario needs
# otherwise), plus non-ATT_ test plumbing.
step_env() {
  local n
  senv=(ATT_ACTION_PATH="$action")
  case $1 in
    check-event.sh) senv+=(ATT_EVENT_NAME=schedule) ;;
    install.sh)
      senv+=(ATT_ACTION_REF='' ATT_CLAUDE_CODE_VERSION="$cc_version" ATT_SNOUTY_VERSION="$snouty_version"
        ATT_SKILLS_REF="$skills_ref" PATH="$tmp/curlbin:$PATH" FAKE_DOWNLOADS="$srv") ;;
    preflight.sh) ;;
    render-prompt.sh)
      for n in runs since limit run-ids run-params grouping known-issues ignore instructions; do
        local var=${n^^}
        senv+=("ATT_IN_${var//-/_}=$(input_default "$n")")
      done
      ;;
    run-agent.sh)
      senv+=(ATT_MODEL="$model" ATT_MAX_TURNS="$(input_default max-turns)"
        ATT_MAX_BUDGET_USD="$(input_default max-budget-usd)" ATT_TIMEOUT_MINUTES="$(input_default timeout-minutes)") ;;
    finalize.sh)
      senv+=(ATT_UPLOAD_TRANSCRIPT=true ATT_GITHUB_TOKEN="$github_token" ATT_AGENT_OUTCOME="$agent_outcome"
        ATT_ARTIFACT_NAME="$artifact_name" ATT_EVENT_NAME=schedule) ;;
    *) return 1 ;;
  esac
}

# scenario <name> <fake claude mode>: a fresh runner, then every `run:` step.
scenario() {
  name=$1
  local mode=$2 base=$tmp/$1 script cond names step rc failed=0 env_ok=1 passed want
  local -a want_names
  work=$base/work
  temp=$work/_temp
  action=$work/_actions/antithesishq/antithesis-triage-action/v0
  ws=$work/bank/bank
  home=$base/home
  fake=$base/fake
  logs=$base/logs
  cmds=$temp/_runner_file_commands
  att=$temp/antithesis-triage
  out=$att/out
  awork=$att/work
  mkdir -p "$action" "$ws" "$home" "$fake" "$logs" "$cmds" "$temp/_github_workflow"
  cp -R "$root/action.yml" "$root/scripts" "$root/shim" "$root/prompts" "$root/schema" "$action/"
  make_repo
  : > "$cmds/set_env"
  : > "$cmds/add_path"
  : > "$cmds/save_state"
  printf '{"schedule": "0 7 * * *", "workflow": ".github/workflows/antithesis-triage.yml"}\n' \
    > "$temp/_github_workflow/event.json"
  jq -n --arg c "$run_commit" --arg id "$run_id" '[{
    run_id: $id, name: "nightly", status: "completed", created_at: "2026-10-27T03:00:12Z",
    parameters: {"antithesis.source": "main", "antithesis.test_name": "nightly", "vcs.version_id": $c},
    links: {triage_report: "https://acme.antithesis.com/report/\($id)/index.html?auth=SECRET-from-snouty"}}]' \
    > "$fake/runs.json"

  job_env=(
    PATH="$PATH" HOME="$home" LANG=C.UTF-8 CI=true GITHUB_ACTIONS=true
    RUNNER_OS=Linux RUNNER_TEMP="$temp" RUNNER_WORKSPACE="$work/bank"
    GITHUB_WORKSPACE="$ws" GITHUB_EVENT_NAME=schedule GITHUB_EVENT_PATH="$temp/_github_workflow/event.json"
    GITHUB_REPOSITORY=acme/bank GITHUB_REPOSITORY_OWNER=acme GITHUB_SHA="$head_sha"
    GITHUB_REF=refs/heads/main GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch
    GITHUB_SERVER_URL=https://github.com GITHUB_API_URL=https://api.github.invalid
    GITHUB_RUN_ID=4242 GITHUB_RUN_NUMBER=17 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=triage
    GITHUB_WORKFLOW="Antithesis triage" GITHUB_ACTION_PATH="$action"
    GITHUB_ACTION_REPOSITORY=antithesishq/antithesis-triage-action
    GITHUB_ENV="$cmds/set_env" GITHUB_PATH="$cmds/add_path" GITHUB_STATE="$cmds/save_state"
    # The caller's step env, as in examples/triage.yml.
    ANTITHESIS_API_KEY="$antithesis_key" ANTITHESIS_TENANT=acme ANTHROPIC_API_KEY="$anthropic_key"
    # Test doubles.
    FAKE_DIR="$fake" FAKE_CLAUDE_MODE="$mode"
  )

  agent_outcome=skipped
  step_rc=()
  step_order=()
  while IFS='|' read -r script cond names; do
    step=${script%.sh}
    step_order+=("$step")
    if [ "$failed" = 1 ] && [[ $cond != *'always()'* ]]; then
      step_rc[$step]=skipped
      continue
    fi
    if ! step_env "$script"; then
      not_ok "$name: action.yml runs $script, which this test does not know"
      step_rc[$step]=unknown
      continue
    fi
    read -ra want_names <<<"$names"
    want=$(printf '%s\n' "${want_names[@]}" | sort | tr '\n' ' ')
    passed=$(printf '%s\n' "${senv[@]%%=*}" | grep '^ATT_' | sort | tr '\n' ' ')
    if [ "$want" != "$passed" ]; then
      env_ok=0
      not_ok "$name: $script gets the env names action.yml passes (action.yml: $want; test: $passed)"
    fi
    rc=0
    (cd "$ws" && exec env -i "${job_env[@]}" \
      GITHUB_OUTPUT="$cmds/set_output_$step" GITHUB_STEP_SUMMARY="$cmds/step_summary_$step" "${senv[@]}" \
      bash --noprofile --norc -eo pipefail -c "\"\$ATT_ACTION_PATH/scripts/$script\"") \
      > "$logs/$step.log" 2>&1 || rc=$?
    step_rc[$step]=$rc
    [ "$rc" = 0 ] || failed=1
    if [ "$script" = run-agent.sh ]; then
      if [ "$rc" = 0 ]; then agent_outcome=success; else agent_outcome=failure; fi
    fi
  done < <(action_steps)
  [ "$env_ok" = 0 ] || ok "$name: every step gets exactly the ATT_* env names action.yml passes"
}

# expect_step <step> <0|nonzero|N>: the step's exit status; shows its log if not.
expect_step() {
  local step=$1 want=$2 got=${step_rc[$1]:-not run} good=0
  case $want in
    nonzero) [[ $got =~ ^[1-9][0-9]*$ ]] && good=1 ;;
    *) [ "$got" = "$want" ] && good=1 ;;
  esac
  if [ "$good" = 1 ]; then
    ok "$name: $step exits $want"
  else
    not_ok "$name: $step exits $want (got $got)"
    indent "$logs/$step.log" | tail -n 40
  fi
}
no_problems() {
  if [ -s "$fake/agent-problems" ]; then
    not_ok "$name: the fake agent found nothing wrong with its prompt, permissions or tools"
    indent "$fake/agent-problems"
  else
    ok "$name: the fake agent found nothing wrong with its prompt, permissions or tools"
  fi
}
runner_files_untouched() {
  check "$name: GITHUB_ENV, GITHUB_PATH and GITHUB_STATE were not written" \
    test ! -s "$cmds/set_env" -a ! -s "$cmds/add_path" -a ! -s "$cmds/save_state"
  check "$name: only finalize sets step outputs" \
    bash -c 'for f in "$1"/set_output_*; do [ "$f" = "$1/set_output_finalize" ] || [ ! -s "$f" ] || exit 1; done' _ "$cmds"
  check "$name: nothing is written to HOME" test -z "$(find "$home" -mindepth 1 -print -quit)"
  check "$name: the checkout is left alone" \
    bash -c '[ -z "$(git -C "$1" status --porcelain)" ] && [ "$(git -C "$1" rev-parse HEAD)" = "$2" ]' _ "$ws" "$head_sha"
}

# ==============================================================================
# 1. success
# ==============================================================================
scenario success success
sid=$(cat "$awork/session-id" 2>/dev/null)
check "action.yml lists the steps this test expects, in order" \
  test "${step_order[*]}" = "check-event install preflight render-prompt run-agent finalize"
for s in check-event install preflight render-prompt run-agent finalize; do expect_step "$s" 0; done

# install.sh: downloads, layout, versions.
check "$name: install fetched only the five release downloads" \
  test "$(grep -cvE '^https://(github\.com/antithesishq/snouty/releases/download/|downloads\.claude\.ai/claude-code-releases/|codeload\.github\.com/antithesishq/antithesis-skills/tar\.gz/)' "$fake/curl.log")-$(wc -l < "$fake/curl.log")" = 0-5
check "$name: bin/snouty is the shim" cmp -s "$att/bin/snouty" "$root/shim/snouty"
check "$name: libexec/snouty is the downloaded snouty" cmp -s "$att/libexec/snouty" "$fx/snouty"
check "$name: bin/claude is the downloaded Claude Code" cmp -s "$att/bin/claude" "$fx/claude"
check "$name: the plugin holds only the antithesis-triage skill" \
  test "$(cd "$att/plugin" && find . -type f | sort | tr '\n' ' ')" = "./.claude-plugin/plugin.json ./skills/antithesis-triage/SKILL.md ./skills/antithesis-triage/references/logs.md "
check "$name: versions.json records the action ref from the _actions path, the versions and the model" \
  jq -e --arg s "$snouty_version" --arg c "$cc_version" --arg r "$skills_ref" --arg m "$model" \
  '.action_ref == "v0" and .snouty == $s and .claude_code == $c and .skills_ref == $r and .model == $m' "$awork/versions.json"

# preflight.sh: the real snouty directly, with the API host pinned.
check "$name: preflight ran snouty doctor --json with the pinned host and the empty settings file" \
  jq -se --arg s "$att/snouty-settings.toml" \
  'map(select(.argv == ["doctor", "--json"])) | length == 1 and (.[0].base_url == "https://acme.antithesis.com") and .[0].settings == $s' \
  "$fake/snouty-calls.jsonl"
check "$name: the snouty settings file is empty" test -f "$att/snouty-settings.toml" -a ! -s "$att/snouty-settings.toml"
check "$name: every snouty call (preflight and agent) has the API host pinned" \
  jq -se 'map(select(.argv != ["--version"])) | length >= 3 and all(.base_url == "https://acme.antithesis.com" and .api_key == "set")' \
  "$fake/snouty-calls.jsonl"
check "$name: the shim refused snouty launch before it reached snouty" \
  jq -se 'all(.argv[0] != "launch")' "$fake/snouty-calls.jsonl"

# render-prompt.sh.
has "$awork/prompt.md" 'default branch `main`.' "$name: prompt.md names GITHUB_REF_NAME as the default branch (schedule payload has no repository)"
has "$awork/prompt.md" "commit \`$head_sha\`, ref \`main\`" "$name: prompt.md names GITHUB_SHA and GITHUB_REF_NAME"
check "$name: inputs.json holds the action.yml defaults" \
  jq -e --arg r "$(input_default runs)" '.runs == $r and .since == "" and .grouping == ""' "$awork/inputs.json"

# run-agent.sh, from the agent's side.
check "$name: claude got prompt.md on stdin, unchanged" cmp -s "$fake/claude-stdin" "$awork/prompt.md"
no_problems
has "$logs/run-agent.log" "[agent] session started: Claude Code $cc_version, model $model, tools Bash,Read,Edit, plugins antithesis-skills" \
  "$name: the log shows the session start with the plugin loaded"
lacks "$logs/run-agent.log" "::warning::" "$name: run-agent prints no warnings"
has "$logs/run-agent.log" "[agent] Bash: snouty launch" "$name: the log shows the launch attempt"
has "$logs/run-agent.log" "[agent] finished: success" "$name: the log shows the result"
check "$name: agent-result.json holds the success result" jq -e '.subtype == "success"' "$awork/agent-result.json"
session_src=$(find "$att/claude-config/projects" -name "$sid.jsonl" 2>/dev/null | head -n 1)
check "$name: the session log is where Claude Code writes it" test -n "$session_src" -a -s "$session_src"
lacks "$awork/stream.jsonl" "SECRET-from-snouty" "$name: the shim stripped snouty's signed links before the agent saw them (stream)"
lacks "$session_src" "SECRET-from-snouty" "$name: the shim stripped snouty's signed links before the agent saw them (session log)"
has "$awork/stream.jsonl" "$antithesis_key" "$name: the agent's raw stream does carry the API key (so redaction is exercised)"

# finalize.sh: outputs and the artifact.
check "$name: finalize outputs redacted=true" test "$(output finalize redacted)" = true
check "$name: finalize outputs status=complete" test "$(output finalize status)" = complete
check "$name: report-path and findings-path point into out/" \
  test "$(output finalize report-path)|$(output finalize findings-path)" = "$out/report.md|$out/findings.json"
upload_path=$(sed -n 's/^        path: \${{ runner\.temp }}\(.*\)$/\1/p' "$root/action.yml")
check "$name: the upload step's path is the directory finalize wrote" test "$temp$upload_path" -ef "$out"
check "$name: the upload step is gated on redacted == 'true'" \
  grep -qF "if: always() && steps.finalize.outputs.redacted == 'true'" "$root/action.yml"
lacks "$logs/finalize.log" "::warning::" "$name: finalize prints no warnings"
lacks "$logs/finalize.log" "::error::" "$name: finalize prints no errors"
for f in report.md findings.json commands.log patches/balance-lock.patch transcript/claude-session.jsonl transcript/transcript.jsonl; do
  check "$name: out/$f exists" test -s "$out/$f"
done
check "$name: the persisted tool output is in the artifact" \
  bash -c 'compgen -G "$1/transcript/claude-session/tool-results/*.txt"' _ "$out"
check "$name: findings.json is valid and complete" \
  bash -c '"$1/scripts/validate-findings.sh" "$2" && jq -e ".status == \"complete\"" "$2"' _ "$root" "$out/findings.json"

# commands.log: the shim's three entries, copied from work/.
check "$name: commands.log has the agent's 3 snouty calls (preflight's doctor is not one)" \
  jq -se --arg r "$run_id" 'length == 3
    and .[0].argv == ["runs", "--json", "list", "-n", "200"] and .[0].exit == 0 and .[0].denied == false
    and .[1].argv[0:4] == ["runs", "--json", "logs", $r] and .[1].exit == 0
    and .[2].argv[0] == "launch" and .[2].exit == 126 and .[2].denied == true' "$out/commands.log"
check "$name: out/commands.log is the shim's log" cmp -s "$out/commands.log" "$awork/commands.log"

# Redaction.
no_secrets "$name: no secret or auth= value anywhere in out/" "$out"
no_secrets "$name: no secret or auth= value in the step summary" "$cmds/step_summary_finalize"
no_secrets "$name: no secret or auth= value in any step's log" "$logs"
for f in findings.json report.md transcript/transcript.jsonl transcript/claude-session.jsonl; do
  has "$out/$f" "[REDACTED:ANTITHESIS_API_KEY]" "$name: out/$f had the API key and it was redacted"
done
check "$name: the persisted tool output had the API key and it was redacted" \
  bash -c 'grep -qF "[REDACTED:ANTITHESIS_API_KEY]" "$1"/transcript/claude-session/tool-results/*.txt' _ "$out"
check "$name: the signed link in findings.json was cut at ?auth=" \
  jq -e --arg u "https://acme.antithesis.com/report/$run_id/index.html" '.runs[0].triage_report_url == $u' "$out/findings.json"

# report.md and the job summary.
report=$out/report.md
has "$report" '**Status:** complete' "$name: report shows the status"
has "$report" '### 1. New: Balance stays nonnegative' "$name: report shows the new failure"
has "$report" "snouty debug --run-id $run_id --input-hash -1520695250096255483 --vtime 67.7622960046865" \
  "$name: report has the snouty debug command"
has "$report" 'Commands run (3 snouty calls, 1 denied)' "$name: report has the Commands run section"
has "$report" '# DENIED: snouty launch --duration 30 --description e2e' "$name: report lists the denied launch"
has "$report" 'Patch: `patches/balance-lock.patch` in the artifact.' "$name: report links the patch, present"
has "$report" "[triage report](https://acme.antithesis.com/report/$run_id/index.html)" "$name: report links the triage report without auth"
has "$report" "https://github.com/acme/bank/blob/$run_commit/src/ledger.rs#L5" "$name: report permalinks the source at the run's commit"
has "$report" "Session id: \`$sid\`" "$name: report gives the session id"
has "$report" "**Versions:** action \`v0\` · snouty \`$snouty_version\` · Claude Code \`$cc_version\`" "$name: report shows the versions"
has "$report" "**Artifact:** \`$artifact_name\`" "$name: report names the artifact"
check "$name: the job summary is the report" cmp -s "$report" "$cmds/step_summary_finalize"

# The patch, built with the prompt's recipe, applies at the run's commit.
mkdir -p "$tmp/apply"
g archive "$run_commit" | tar -x -C "$tmp/apply"
check "$name: the patch applies with git apply at the run's commit" \
  bash -c 'cd "$1" && git apply --check "$2"' _ "$tmp/apply" "$out/patches/balance-lock.patch"

# transcript.jsonl: normalized from the same stream and session.
tr_file=$out/transcript/transcript.jsonl
check "$name: transcript header has the session, model, versions and result" \
  jq -se --arg sid "$sid" --arg m "$model" --arg c "$cc_version" '.[0] | .type == "header" and .session_id == $sid
    and .model == $m and .claude_code_version == $c and .versions.action_ref == "v0" and .result.subtype == "success"' "$tr_file"
check "$name: transcript has the prompt, tool calls and tool results" \
  jq -se '(.[1].role == "system") and (.[2].role == "user") and (.[2].content | startswith("/antithesis-skills:antithesis-triage"))
    and ([.[] | select(.role == "assistant") | .tool_calls[]?] | length) == ([.[] | select(.role == "tool")] | length)
    and ([.[] | select(.role == "tool")] | length) >= 10' "$tr_file"
check "$name: transcript keeps the shim's refusal as an error result" \
  jq -se 'any(.[]; .role == "tool" and .is_error == true and (.content | contains("snouty shim: denied")))' "$tr_file"
runner_files_untouched

# ==============================================================================
# 2. max_turns: in_progress findings.json -> partial
# ==============================================================================
scenario max_turns max_turns
for s in check-event install preflight render-prompt; do expect_step "$s" 0; done
expect_step run-agent 1
expect_step finalize nonzero
no_problems
has "$logs/run-agent.log" "::error::The agent stopped at the max-turns cap ($(input_default max-turns))." "$name: run-agent explains the cap"
check "$name: finalize outputs status=partial" test "$(output finalize status)" = partial
check "$name: finalize outputs redacted=true (so the artifact is uploaded)" test "$(output finalize redacted)" = true
check "$name: findings.json is partial and says why" \
  jq -e '.status == "partial" and any(.errors[]; contains("outcome: failure, result: error_max_turns"))' "$out/findings.json"
has "$out/report.md" '> **Partial results.**' "$name: report flags partial results"
has "$out/report.md" '**Agent session:** error_max_turns' "$name: report shows how the session ended"
has "$out/report.md" 'Commands run (1 snouty calls, 0 denied)' "$name: report lists the one snouty call"
for f in report.md findings.json commands.log transcript/claude-session.jsonl transcript/transcript.jsonl; do
  check "$name: out/$f exists" test -s "$out/$f"
done
check "$name: transcript header has the error_max_turns result" \
  jq -se '.[0].result.subtype == "error_max_turns"' "$out/transcript/transcript.jsonl"
no_secrets "$name: no secret or auth= value anywhere in out/" "$out"
no_secrets "$name: no secret or auth= value in the step summary" "$cmds/step_summary_finalize"
no_secrets "$name: no secret or auth= value in any step's log" "$logs"
has "$out/findings.json" "[REDACTED:ANTITHESIS_API_KEY]" "$name: the in_progress findings.json had the API key and it was redacted"
check "$name: the job summary is the report" cmp -s "$out/report.md" "$cmds/step_summary_finalize"
runner_files_untouched

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
