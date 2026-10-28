#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $ and backticks in expected strings
# Tests for scripts/render-report.sh.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/render-report.sh
fx=$root/test/fixtures
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
zwj=$'‍'

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
has() { # name file literal
  if grep -qF -- "$3" "$2"; then ok "$1"; else not_ok "$1: '$3' not found"; fi
}
lacks() { # name file literal
  if grep -qF -- "$3" "$2"; then not_ok "$1: unexpected '$3'"; else ok "$1"; fi
}
render() { # out findings [extra args...]
  local o=$1 f=$2
  shift 2
  env -u GITHUB_SERVER_URL -u GITHUB_REPOSITORY -u GITHUB_RUN_ID -u GITHUB_RUN_NUMBER -u GITHUB_RUN_ATTEMPT \
    ATT_REPORT_DATE=2026-10-28 "${gh_env[@]}" "$script" --findings "$f" --out "$o" "$@"
}

# --- full fixture, transcripts included --------------------------------------
gh_env=(GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/bank GITHUB_RUN_ID=999 GITHUB_RUN_NUMBER=12 GITHUB_RUN_ATTEMPT=2)
art=$tmp/art
mkdir -p "$art/patches"
echo 'diff' >"$art/patches/balance-nonnegative.patch"
r=$tmp/report.md
if render "$r" "$fx/findings.json" --commands-log "$fx/commands.log" --versions "$fx/versions.json" \
  --inputs "$fx/inputs.json" --artifact-dir "$art" --session-id 7b1d6a52-3c0e-4f43-9d1e-2a6f0c9e8b11 \
  --transcripts included; then ok "renders fixture"; else not_ok "render failed"; fi

has "title" "$r" "# Antithesis triage report"
has "status and artifact" "$r" '**Status:** complete · **Repository:** `acme/bank` · **Artifact:** `antithesis-triage-12-2` ([workflow run](https://github.com/acme/bank/actions/runs/999))'
has "versions" "$r" '**Versions:** action `v0.1.0` · snouty `0.8.0` · Claude Code `2.1.312` · triage skill `ca4b8fba0991` · model `claude-opus-5-5`'
has "inputs, multi-line" "$r" '  antithesis.test_name=nightly'
has "selection" "$r" '**Selection applied** (4 runs considered):'
has "grouping inferred" "$r" '**Grouping applied** (inferred by the agent):'
has "skipped run" "$r" '- `r-0d01`: Still starting; no results yet.'
has "runs table header" "$r" '| Run | Created | Group | Commit | Status | Failed (new) | Passed | Instrumentation | Report | Notes |'
has "runs row with commit link and new count" "$r" '| `r-0c3f` | 2026-10-27 03:00 | main/nightly | [`9f1e2d3`](https://github.com/acme/bank/commit/9f1e2d3c4b5a69788776655443322110ffeeddcc) | completed | 2 (1 new) | 41 | ok | [triage report](https://acme.antithesis.com/report/r-0c3f/index.html) | First run after the ledger refactor \| PR #88 |'
has "missing commit and report" "$r" '| `r-0a12` | 2026-10-25 03:00 | main/nightly | - | incomplete | 1 (0 new) | 30 | **unknown** | - |'
lacks "auth query stripped from report links" "$r" 'auth='
has "failure heading" "$r" '### 1. New: Balance stays nonnegative'
has "baseline runs" "$r" '- **Classification:** new (compared against `r-0b77`, `r-0a12`)'
has "evidence line" "$r" 'Run `r-0c3f` · input hash `-1520695250096255483` · vtime `67.7622960046865` · container `bank`'
has "excerpt fence longer than its content" "$r" '````text'
has "permalink" "$r" '[`src/ledger.rs#L142`](https://github.com/acme/bank/blob/9f1e2d3c4b5a69788776655443322110ffeeddcc/src/ledger.rs#L142) at `9f1e2d3`: check-then-act on the balance'
has "permalink falls back to the run commit" "$r" '[`src/ledger.rs`](https://github.com/acme/bank/blob/9f1e2d3c4b5a69788776655443322110ffeeddcc/src/ledger.rs) at `9f1e2d3`'
has "permalink path encoded" "$r" '/blob/9f1e2d3/docs/locking%20notes.md#L7'
has "diff block kept" "$r" '+    let _g = self.accounts_lock.lock();'
has "patch file" "$r" 'Patch: `patches/balance-nonnegative.patch` in the artifact.'
has "debug command" "$r" 'snouty debug --run-id r-0c3f --input-hash -1520695250096255483 --vtime 67.7622960046865 --title "Balance stays nonnegative 2026-10-28"'
has "debug follow-up exec" "$r" '# snouty runs exec <session-run-id> -1520695250096255483 67.7622960046865 --source-run-id r-0c3f '"'"'ps aux'"'"
has "reproduce commands" "$r" "snouty runs search r-0c3f 'filter(ev => ev.antithesis_assert?.id == \"Balance stays nonnegative\")'"
has "known issues collapsed" "$r" '<details><summary>Known issues: 1 matched (1 diverged), 1 not seen</summary>'
has "known issue diverged" "$r" '(**diverged**): Matches by property name.'
has "known issue not seen" "$r" '- "Snapshot restores cleanly": tracked in #140'
has "run health" "$r" '- Instrumentation not confirmed for: `r-0a12` (unknown)'
has "ignored count" "$r" '- Harness heartbeat: 3'
has "skipped for budget" "$r" '- Compaction finishes: Budget: skipped after the two failures above.'
has "resume command" "$r" 'claude --resume "$PWD/transcript/claude-session.jsonl" --fork-session --plugin-dir ./plugin --model claude-opus-5-5'
has "session id" "$r" 'Session id: `7b1d6a52-3c0e-4f43-9d1e-2a6f0c9e8b11`.'
has "commands appendix" "$r" '<details><summary>Commands run (5 snouty calls, 1 denied)</summary>'
has "command line with exit and duration" "$r" 'snouty --json runs list --since 7d  # exit 0, 0.8s'
has "denied command commented out" "$r" '# DENIED: snouty launch --duration 30'
has "control characters quoted" "$r" "snouty runs logs r-0c3f --grep \$'it\\'s\\nmultiline'  # exit 1, 15s"
has "bad commands.log line counted" "$r" '_1 unreadable line(s) in commands.log were skipped._'

# Neutralized model output.
has "mention neutralized" "$r" "Ping @${zwj}octocat"
has "team mention neutralized" "$r" "cc @${zwj}acme/bank-team"
lacks "no raw img tag" "$r" '<img'
has "img tag neutralized" "$r" "<${zwj}img src="
lacks "no markdown image" "$r" '![tracking]'
has "autolink kept" "$r" '<https://example.com/docs>'
has "script inside fence untouched" "$r" '<script>alert(1)</script>'

# --- withheld transcripts, no GitHub env, minimal inputs ----------------------
gh_env=()
r2=$tmp/report2.md
render "$r2" "$fx/findings.json" --transcripts withheld --transcripts-reason "upload-transcript is auto and the repository is public." \
  && ok "renders without optional files" || not_ok "render without optional files failed"
has "withheld reason" "$r2" 'Transcripts were withheld from this artifact: upload-transcript is auto and the repository is public.'
has "no commands logged" "$r2" '_No snouty calls were logged._'
has "inputs default" "$r2" '**Inputs:** all defaults.'
lacks "no links without repository" "$r2" '](https://github.com'
has "plain source ref without repository" "$r2" '- `src/ledger.rs#L142` at `9f1e2d3`: check-then-act on the balance'
lacks "no patch existence check without artifact dir" "$r2" '**missing**'

# --- adversarial findings ------------------------------------------------------
gh_env=(GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/bank)
jq '
  .failures[0].property = "Bad $(touch /tmp/pwned) `x` \"q\" <b>"
  | .failures[0].root_cause = "open fence:\n```\n<img src=x>\nnever closed"
  | .failures[0].suggested_fix = "    ```\n<img src=y> after an indented fence"
  | .failures[1].root_cause = "- item\n  ```\n  code\n<img src=w> after a list-item fence"
  | .failures[0].evidence[0].excerpt = "plain excerpt"
  | .failures[0].recommended_debug_session.run_id = "r 1; rm -rf ~"
  | .failures[0].source_refs = [{path: "../../etc/passwd", line: 1, commit: "9f1e2d3", note: "x"},
                               {path: "src/a.rs", line: 2, commit: "main) [evil](https://evil", note: "y"}]
  | .failures[0].patch_file = "patches/missing.patch"
  | .runs[0].triage_report_url = "javascript:alert(1)"
  | .runs[1].triage_report_url = "https://ok.example/r?x=1&auth=SIG#t"
  | .runs[0].commit = "not-a-sha"
  | .errors = ["snouty failed: <img src=z>"]
  | .status = "partial"
' "$fx/findings.json" >"$tmp/adv.json"
r3=$tmp/report3.md
render "$r3" "$tmp/adv.json" --artifact-dir "$art" && ok "renders adversarial findings" || not_ok "adversarial render failed"
has "partial banner" "$r3" '> **Partial results.**'
has "errors listed and neutralized" "$r3" "- snouty failed: <${zwj}img src=z>"
has "debug title single-quoted" "$r3" "--title 'Bad \$(touch /tmp/pwned) \`x\` \"q\" <b> 2026-10-28'"
has "debug run id quoted" "$r3" "--run-id 'r 1; rm -rf ~'"
has "heading neutralized" "$r3" "### 1. New: Bad \$(touch /tmp/pwned) \`x\` \"q\" <${zwj}b>"
lacks "no raw img anywhere outside fences" "$r3" '<img src=y>'
lacks "list-item fence does not hide html" "$r3" '<img src=w>'
if [[ $(cat "$r3") == *$'never closed\n```'* ]]; then ok "unclosed fence closed"; else not_ok "unclosed fence not closed"; fi
fences=$(grep -cE '^(```|~~~)' "$r3")  # column-0 fences; the list-item one is indented
if (( fences % 2 == 0 )); then ok "fences balanced ($fences)"; else not_ok "odd number of fence lines: $fences"; fi
lacks "no link for traversal path" "$r3" '/blob/9f1e2d3/../'
has "traversal path shown as code" "$r3" '- `../../etc/passwd#L1` at `9f1e2d3`: x'
lacks "no link for bogus commit" "$r3" '[evil](https://evil'
has "missing patch flagged" "$r3" 'Patch: `patches/missing.patch` in the artifact (**missing**: the file was not written).'
lacks "javascript url dropped" "$r3" 'javascript:'
has "auth stripped mid-query" "$r3" '[triage report](https://ok.example/r?x=1#t)'
has "bogus commit as code" "$r3" '| `not-a-sha` |'

# --- minimal failed findings ----------------------------------------------------
jq -n '{schema_version:"0.1",status:"failed",summary:"x",selection:{applied:"",runs_considered:0},grouping:{applied:"",inferred:true},runs:[],skipped_runs:[],failures:[],known_issues_not_seen:[],ignored:[],not_investigated:[],run_health:[],errors:["findings.json was not written by the agent."]}' >"$tmp/min.json"
r4=$tmp/report4.md
render "$r4" "$tmp/min.json" && ok "renders minimal findings" || not_ok "minimal render failed"
has "failed banner" "$r4" '> **The triage did not complete.**'
has "error shown" "$r4" '- findings.json was not written by the agent.'
has "no runs" "$r4" '_No runs were triaged._'
has "no failures" "$r4" '_No new, ongoing, or unclear failures._'

# --- errors -----------------------------------------------------------------------
if "$script" --findings "$tmp/nope.json" --out "$tmp/x.md" 2>/dev/null; then not_ok "missing findings should fail"; else ok "missing findings fails"; fi
if "$script" --out "$tmp/x.md" 2>/dev/null; then not_ok "usage error expected"; else ok "usage error"; fi

[[ $fails -eq 0 ]]
