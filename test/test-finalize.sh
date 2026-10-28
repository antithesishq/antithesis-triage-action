#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $ and backticks in expected strings
# Tests for scripts/finalize.sh (and, through it, the other finalize scripts).
# No network: ATT_UPLOAD_TRANSCRIPT is always set, and the "auto" cases use a
# fake curl on PATH.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/finalize.sh
fx=$root/test/fixtures
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
sid=$(cat "$fx/session-id")
secret='test-antithesis-key-0123456789'

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { # name command...
  local name=$1
  shift
  if "$@" >/dev/null; then ok "$name"; else not_ok "$name"; fi
}

# setup <case>: a fresh $ATT_HOME with the files earlier steps would leave.
setup() {
  home=$tmp/$1
  out=$home/out work=$home/work cfg=$home/claude-config
  mkdir -p "$out/patches" "$work" "$cfg/projects/-home-runner-work-bank-bank/$sid/tool-results"
  cp "$fx/findings.json" "$out/findings.json"
  cp "$fx/commands.log" "$work/commands.log"
  echo '{"argv":["forged"]}' >"$out/commands.log" # the agent can write here; finalize must replace it
  echo 'diff --git a/src/ledger.rs b/src/ledger.rs' >"$out/patches/balance-nonnegative.patch"
  cp "$fx/stream.jsonl" "$fx/inputs.json" "$fx/session-id" "$work/"
  jq '.model = "claude-opus-5-5"' "$fx/versions.json" >"$work/versions.json"
  printf 'Run /antithesis-skills:antithesis-triage\nAPI key for the record: %s\n' "$secret" >"$work/prompt.md"
  grep '"type":"result"' "$fx/stream.jsonl" >"$work/agent-result.json"
  printf '{"type":"user","message":{"role":"user","content":"key %s"}}\n' "$secret" \
    >"$cfg/projects/-home-runner-work-bank-bank/$sid.jsonl"
  echo "persisted output mentioning $secret" >"$cfg/projects/-home-runner-work-bank-bank/$sid/tool-results/x.txt"
  : >"$home/summary.md"
  : >"$home/output"
}

# fin <outcome> <upload-transcript> [extra env...]: run finalize for the current case.
fin() {
  local outcome=$1 upload=$2
  shift 2
  rc=0
  log=$(env -i PATH="${fake_path:+$fake_path:}$PATH" HOME="$home" \
    ATT_ACTION_PATH="$root" ATT_HOME="$home" ATT_OUT="$out" ATT_WORK="$work" \
    ATT_COMMANDS_LOG="$work/commands.log" CLAUDE_CONFIG_DIR="$cfg" \
    ATT_AGENT_OUTCOME="$outcome" ATT_UPLOAD_TRANSCRIPT="$upload" \
    ATT_GITHUB_TOKEN=ghs_faketoken0123456789abcdefghijklmnop ATT_ARTIFACT_NAME=antithesis-triage-nightly-1 \
    ANTITHESIS_API_KEY="$secret" ANTITHESIS_TENANT=acme ANTHROPIC_API_KEY=sk-ant-api03-fakefakefakefake \
    GITHUB_OUTPUT="$home/output" GITHUB_STEP_SUMMARY="$home/summary.md" GITHUB_EVENT_NAME=schedule \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/bank GITHUB_API_URL=https://api.invalid \
    GITHUB_RUN_ID=999 \
    "$@" bash "$script" 2>&1) || rc=$?
}
output() { sed -n "s/^$1=//p" "$home/output"; }
fstatus() { jq -r .status "$out/findings.json"; }

# --- 1. success, transcripts on ----------------------------------------------
setup ok
printf 'patch\0 with a NUL byte and %s' "$secret" >"$out/patches/binary.patch"
fin success true
check "success: exit 0" test "$rc" -eq 0
check "success: status output" test "$(output status)" = complete
check "success: redacted output" test "$(output redacted)" = true
check "success: report-path output" test "$(output report-path)" = "$out/report.md"
check "success: findings-path output" test "$(output findings-path)" = "$out/findings.json"
check "success: report rendered" grep -q '### 1. New: Balance stays nonnegative' "$out/report.md"
check "success: summary is the report" cmp -s "$out/report.md" "$home/summary.md"
check "success: real commands.log published" grep -q '"--created-after"' "$out/commands.log"
check "success: forged commands.log replaced" bash -c '! grep -q forged "$1"' _ "$out/commands.log"
check "success: commands appendix from the shim log" grep -q 'Commands run (6 snouty calls, 1 denied)' "$out/report.md"
check "success: NUL file moved out of the artifact" test ! -e "$out/patches/binary.patch"
check "success: NUL file kept in quarantine" test -e "$work/quarantine/out/patches/binary.patch"
check "success: NUL file noted in the report" grep -qF -- '- `patches/binary.patch`: contains NUL bytes' "$out/report.md"
check "success: raw session log copied" test -s "$out/transcript/claude-session.jsonl"
check "success: session sidecar copied" test -f "$out/transcript/claude-session/tool-results/x.txt"
check "success: normalized transcript" test "$(head -n 1 "$out/transcript/transcript.jsonl" | jq -r .type)" = header
check "success: header has inputs and versions" \
  jq -e 'select(.type == "header") | .inputs.since == "7d" and .versions.snouty == "0.8.0" and .session_id != null' "$out/transcript/transcript.jsonl"
check "success: prompt is the first user message" \
  jq -se '[.[] | select(.role == "user")][0].content | startswith("Run /antithesis-skills:antithesis-triage")' "$out/transcript/transcript.jsonl"
check "success: large tool result spilled" test -s "$out/transcript/tool-results/toolu_02B.txt"
check "success: spilled pointer" grep -q 'full text in tool-results/toolu_02B.txt' "$out/transcript/transcript.jsonl"
check "success: staging cleaned up" test ! -e "$work/transcript" -a ! -e "$work/transcript-src"
check "success: transcripts mentioned as included" grep -q 'claude --resume' "$out/report.md"
if grep -rqF -e "$secret" -e 'ghs_faketoken' -e 'sk-ant-api03-fake' -e 'auth=v2' "$out"; then
  not_ok "success: secrets or auth strings left in the artifact: $(grep -rlF -e "$secret" -e 'auth=v2' "$out")"
else
  ok "success: artifact redacted"
fi
check "success: redaction marker in spilled result" grep -q 'REDACTED:ANTITHESIS_API_KEY' "$out/transcript/tool-results/toolu_02B.txt"
check "success: findings still valid" "$root/scripts/validate-findings.sh" "$out/findings.json"
if [[ $log == *"$secret"* ]]; then not_ok "success: secret in log"; else ok "success: secret not in log"; fi

# --- 2. a secret straddling the tool-result preview cut is still redacted ----------
setup split
pad=$(head -c 990 /dev/zero | tr '\0' 'a')
filler=$(head -c 20000 /dev/zero | tr '\0' 'b')
{
  head -n 1 "$fx/stream.jsonl"
  jq -cn '{type:"assistant",message:{id:"m1",role:"assistant",content:[{type:"tool_use",id:"toolu_S",name:"Bash",input:{command:"snouty runs --json show x"}}]},parent_tool_use_id:null}'
  jq -cn --arg c "$pad$secret$filler" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_S",content:$c}]},parent_tool_use_id:null}'
} >"$work/stream.jsonl"
fin success true
check "split: preview exists" grep -q 'full text in tool-results/toolu_S.txt' "$out/transcript/transcript.jsonl"
check "split: no fragment of the secret in the artifact" bash -c '! grep -rqF "${2:0:10}" "$1"' _ "$out" "$secret"

# --- 3. transcripts off -----------------------------------------------------------
setup off
fin success false
check "off: exit 0" test "$rc" -eq 0
check "off: no transcript dir" test ! -e "$out/transcript"
check "off: withheld reason in report" grep -q 'Transcripts were withheld from this artifact: upload-transcript is false.' "$out/report.md"

# --- 4. findings missing, agent hit max turns ----------------------------------
setup missing
rm "$out/findings.json"
jq -c '.subtype = "error_max_turns" | .is_error = true' "$work/agent-result.json" >"$work/r.json" && mv "$work/r.json" "$work/agent-result.json"
fin failure false
check "missing: exit 1" test "$rc" -eq 1
check "missing: status failed" test "$(fstatus)" = failed
check "missing: status output" test "$(output status)" = failed
check "missing: still uploadable" test "$(output redacted)" = true
check "missing: errors explain" jq -e '.errors | index("findings.json was not written by the agent.") and (map(select(contains("error_max_turns"))) | length == 1)' "$out/findings.json"
check "missing: minimal findings valid" "$root/scripts/validate-findings.sh" "$out/findings.json"
check "missing: report says incomplete" grep -q 'The triage did not complete' "$out/report.md"

# --- 5. invalid findings, agent succeeded ---------------------------------------
setup invalid
cp "$fx/findings.invalid.json" "$out/findings.json"
fin success false
check "invalid: exit 1" test "$rc" -eq 1
check "invalid: original kept" cmp -s "$out/findings.invalid.json" "$fx/findings.invalid.json"
check "invalid: status failed" test "$(fstatus)" = failed
check "invalid: violations in errors" jq -e '.errors | map(select(startswith("schema: $.failures[0].confidence"))) | length == 1' "$out/findings.json"
check "invalid: report lists violations" grep -qF 'schema: $.status: "done" is not one of' "$out/report.md"
check "invalid: values not echoed to the log" bash -c '! grep -q "very high" <<<"$1"' _ "$log"

# --- 6. in_progress -> partial ----------------------------------------------------
setup partial
jq '.status = "in_progress"' "$fx/findings.json" >"$out/findings.json"
fin failure false
check "partial (agent failed): exit 1" test "$rc" -eq 1
check "partial (agent failed): status partial" test "$(fstatus)" = partial
check "partial (agent failed): output" test "$(output status)" = partial
check "partial (agent failed): note added" jq -e '.errors | map(select(contains("outcome: failure"))) | length == 1' "$out/findings.json"

setup partial2
jq '.status = "in_progress"' "$fx/findings.json" >"$out/findings.json"
fin success false
check "partial (agent ok): exit 0" test "$rc" -eq 0
check "partial (agent ok): status partial" test "$(fstatus)" = partial

# --- 7. preflight failed: agent skipped, nothing written -------------------------------
setup skipped
rm -f "$out/findings.json" "$out/commands.log" "$work/stream.jsonl" "$work/session-id" "$work/prompt.md" \
  "$work/agent-result.json" "$work/commands.log"
rm -rf "$cfg/projects"
fin skipped true
check "skipped: exit 1" test "$rc" -eq 1
check "skipped: report rendered" test -s "$out/report.md"
check "skipped: setup failure explained" grep -q 'preflight (snouty doctor) or prompt rendering failed' "$out/report.md"
check "skipped: no transcript dir" test ! -e "$out/transcript"
check "skipped: withheld because nothing found" grep -q 'no session log or agent output was found' "$out/report.md"
check "skipped: no commands.log" test ! -e "$out/commands.log"

# --- 8. install never ran: only RUNNER_TEMP, no ATT_HOME ----------------------------
home=$tmp/noinstall
mkdir -p "$home"
: >"$home/output"
: >"$home/summary.md"
rc=0
log=$(env -i PATH="$PATH" HOME="$home" ATT_ACTION_PATH="$root" RUNNER_TEMP="$home/runner-temp" \
  ATT_AGENT_OUTCOME=skipped ATT_UPLOAD_TRANSCRIPT=auto GITHUB_EVENT_NAME=workflow_dispatch \
  GITHUB_OUTPUT="$home/output" GITHUB_STEP_SUMMARY="$home/summary.md" bash "$script" 2>&1) || rc=$?
check "no install: exit 1" test "$rc" -eq 1
check "no install: report in the derived ATT_OUT" test -s "$home/runner-temp/antithesis-triage/out/report.md"
check "no install: summary explains" grep -q 'the install step failed, so the agent never started' "$home/summary.md"
check "no install: status failed" test "$(output status)" = failed
check "no install: artifact still uploadable" test "$(output redacted)" = true

# --- 9. refused event ---------------------------------------------------------------
home=$tmp/refused
mkdir -p "$home"
: >"$home/output"
: >"$home/summary.md"
rc=0
log=$(env -i PATH="$PATH" HOME="$home" ATT_ACTION_PATH="$root" RUNNER_TEMP="$home/runner-temp" \
  ATT_AGENT_OUTCOME=skipped ATT_UPLOAD_TRANSCRIPT=false GITHUB_EVENT_NAME=pull_request_target \
  GITHUB_OUTPUT="$home/output" GITHUB_STEP_SUMMARY="$home/summary.md" bash "$script" 2>&1) || rc=$?
check "refused: exit 1" test "$rc" -eq 1
check "refused: summary explains" grep -q 'runs only on `schedule` and `workflow_dispatch` events, not `pull_request_target`' "$home/summary.md"
check "refused: status failed" test "$(output status)" = failed
check "refused: no upload" test "$(output redacted)" = false
check "refused: nothing created" test ! -e "$home/runner-temp"

# --- 10. nowhere to write ---------------------------------------------------------------
home=$tmp/nowhere
mkdir -p "$home"
: >"$home/output"
: >"$home/summary.md"
rc=0
log=$(env -i PATH="$PATH" ATT_ACTION_PATH="$root" ATT_AGENT_OUTCOME=skipped ATT_UPLOAD_TRANSCRIPT=false \
  GITHUB_OUTPUT="$home/output" GITHUB_STEP_SUMMARY="$home/summary.md" bash "$script" 2>&1) || rc=$?
check "nowhere: exit 1" test "$rc" -eq 1
check "nowhere: summary line" grep -q 'Antithesis triage did not run' "$home/summary.md"
check "nowhere: status output" test "$(output status)" = failed
check "nowhere: error logged" grep -q '^::error::' <<<"$log"

# --- 11. auto visibility via a fake curl --------------------------------------------
fake=$tmp/fakebin
mkdir -p "$fake"
cat >"$fake/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_CURL_LOG.argv"
cat >"$FAKE_CURL_LOG.stdin"
case $FAKE_CURL_MODE in
  private) echo '{"private": true}' ;;
  public) echo '{"private": false}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$fake/curl"
fake_path=$fake

setup auto-private
fin success auto FAKE_CURL_MODE=private FAKE_CURL_LOG="$home/curl"
check "auto private: transcripts included" test -s "$out/transcript/transcript.jsonl"
check "auto private: queried the repo" grep -q 'https://api.invalid/repos/acme/bank' "$home/curl.argv"
check "auto private: token not in argv" bash -c '! grep -q ghs_faketoken "$1"' _ "$home/curl.argv"
check "auto private: token sent on stdin" grep -q 'Authorization: Bearer ghs_faketoken' "$home/curl.stdin"

setup auto-public
fin success auto FAKE_CURL_MODE=public FAKE_CURL_LOG="$home/curl"
check "auto public: no transcripts" test ! -e "$out/transcript"
check "auto public: reason" grep -q 'upload-transcript is auto and the repository is public.' "$out/report.md"

setup auto-error
fin success auto FAKE_CURL_MODE=error FAKE_CURL_LOG="$home/curl"
check "auto error: no transcripts" test ! -e "$out/transcript"
check "auto error: reason" grep -q "visibility could not be determined" "$out/report.md"
fake_path=''

# --- 12. job summary truncation ------------------------------------------------------
setup big
big=$(head -c 1200000 /dev/zero | tr '\0' 'x' | fold -w 100)
jq --rawfile big <(printf '%s\n' "$big") '.failures[0].evidence[0].excerpt = $big' "$fx/findings.json" >"$out/findings.json"
fin success false
size=$(wc -c <"$home/summary.md")
check "big: exit 0" test "$rc" -eq 0
check "big: full report in artifact" test "$(wc -c <"$out/report.md")" -gt 1200000
check "big: summary under 1 MiB but not empty ($size bytes)" test "$size" -lt 1048576 -a "$size" -gt 1000000
check "big: truncation note" grep -q 'This report was truncated to fit the job summary.' "$home/summary.md"
check "big: note points to the artifact" grep -qF 'the artifact `antithesis-triage-nightly-1` on the [workflow run page](https://github.com/acme/bank/actions/runs/999)' "$home/summary.md"
# The cut lands inside the excerpt's code fence; it must be closed before the note.
check "big: open fence closed before the note" \
  bash -c 'grep -B4 "This report was truncated" "$1" | grep -qx "\`\`\`"' _ "$home/summary.md"

# --- 13. symlinks are dropped from the artifact ----------------------------------------
setup symlink
ln -s /etc/hostname "$out/patches/link.patch"
fin success false
check "symlink: removed" test ! -e "$out/patches/link.patch" -a ! -L "$out/patches/link.patch"
check "symlink: warned" grep -q 'Removing a non-regular file' <<<"$log"

[[ $fails -eq 0 ]]
