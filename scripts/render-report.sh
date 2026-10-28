#!/usr/bin/env bash
# Render report.md from findings.json and the run's side files.
#
# Usage: render-report.sh --findings findings.json --out report.md
#          [--commands-log commands.log] [--versions versions.json]
#          [--inputs inputs.json] [--agent-result agent-result.json]
#          [--artifact-dir DIR] [--session-id ID]
#          [--transcripts included|withheld] [--transcripts-reason TEXT]
#
# Reads GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_NUMBER
# and GITHUB_RUN_ATTEMPT for links (optional), and ATT_REPORT_DATE (YYYY-MM-DD,
# defaults to today, UTC) for debugging-session titles.
#
# Findings text is model output derived from untrusted logs, so it is
# neutralized before it reaches markdown: "<tag" and "![image" get a
# zero-width joiner so GitHub renders neither raw HTML nor remote images,
# @mentions get one so nobody is pinged, links and permalinks are only built
# from validated values, literals go in code spans/fences sized to their
# content, and shell commands are quoted for safe pasting.
set -euo pipefail

usage() {
  echo "usage: $0 --findings F --out F [--commands-log F] [--versions F] [--inputs F] [--agent-result F] [--artifact-dir D] [--session-id ID] [--transcripts included|withheld] [--transcripts-reason TEXT]" >&2
  exit 2
}

findings='' out='' commands_log='' versions='' inputs='' agent_result=''
artifact_dir='' session_id='' transcripts='withheld' transcripts_reason=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --findings) findings=$2 ;;
    --out) out=$2 ;;
    --commands-log) commands_log=$2 ;;
    --versions) versions=$2 ;;
    --inputs) inputs=$2 ;;
    --agent-result) agent_result=$2 ;;
    --artifact-dir) artifact_dir=$2 ;;
    --session-id) session_id=$2 ;;
    --transcripts) transcripts=$2 ;;
    --transcripts-reason) transcripts_reason=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n $findings && -n $out ]] || usage

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Copy an optional JSON file to $work/<name>.json, or write null if it is
# missing/invalid. Values go to jq via files: argv strings are capped at 128 KiB.
load_json() {
  if [[ -n $2 && -s $2 ]] && jq -e . "$2" >/dev/null 2>&1; then
    jq -c . "$2" >"$work/$1.json"
  else
    echo null >"$work/$1.json"
  fi
}

load_json findings "$findings"
if [[ $(head -c 4 "$work/findings.json") == null ]]; then
  echo "render-report: $findings is missing or not valid JSON" >&2
  exit 1
fi
load_json versions "$versions"
load_json inputs "$inputs"
load_json agent "$agent_result"

# Which patch files referenced by the findings exist in the artifact.
echo null >"$work/patches.json"
if [[ -n $artifact_dir ]]; then
  jq -r '.failures[]?.patch_file | strings' "$work/findings.json" |
    while IFS= read -r p; do
      if [[ -f $artifact_dir/$p ]]; then printf '%s\n' "$p"; fi
    done | jq -R . | jq -cs . >"$work/patches.json"
fi

cmdlog=/dev/null
if [[ -n $commands_log && -f $commands_log ]]; then
  cmdlog=$commands_log
fi

repo_url=''
if [[ -n ${GITHUB_SERVER_URL:-} && -n ${GITHUB_REPOSITORY:-} ]]; then
  repo_url="${GITHUB_SERVER_URL%/}/$GITHUB_REPOSITORY"
fi
run_url=''
if [[ -n $repo_url && -n ${GITHUB_RUN_ID:-} ]]; then
  run_url="$repo_url/actions/runs/$GITHUB_RUN_ID"
fi
artifact_name=''
if [[ -n ${GITHUB_RUN_NUMBER:-} ]]; then
  artifact_name="antithesis-triage-$GITHUB_RUN_NUMBER-${GITHUB_RUN_ATTEMPT:-1}"
fi

# shellcheck disable=SC2016  # jq program, not shell
program='
  def zwj: "\u200d";

  # --- neutralizing untrusted text ------------------------------------------

  # One line of markdown outside code fences.
  def neutralize_line:
    gsub("<(?!https?://[^\\s<>]+>)(?<c>[A-Za-z/!?])"; "<\(zwj)\(.c)")
    | gsub("!\\["; "!\(zwj)[")
    | gsub("(?<![A-Za-z0-9_/.`-])@(?=[A-Za-z0-9])"; "@\(zwj)");

  # Single-line text (headings, list items, table cells).
  def text: (. // "") | tostring | gsub("[\r\n]+"; " ") | neutralize_line;

  # Multi-line markdown: neutralize outside fenced code blocks, leave fence
  # contents alone, and close a fence the text left open. Only fences that
  # start in column 0 count: an indented one may belong to a list item that
  # GitHub ends (and the fence with it) at the next unindented line.
  def md:
    (. // "") | tostring | rtrimstr("\n") | split("\n")
    | reduce .[] as $l ({out: [], fence: null};
        if .fence == null then
          ([$l | capture("^(?<f>`{3,}|~{3,})(?<info>.*)$")][0]) as $m
          | if $m != null and (($m.f[0:1] == "~") or ($m.info | contains("`") | not)) then
              .fence = {c: $m.f[0:1], n: ($m.f | length)} | .out += [$l]
            else .out += [$l | neutralize_line] end
        else
          .fence as $fe
          | if ($l | test("^ {0,3}" + $fe.c + "{\($fe.n),}[ \t]*$"))
            then .fence = null | .out += [$l]
            else .out += [$l] end
        end)
    | .out + (if .fence then [.fence.c * .fence.n] else [] end)
    | join("\n");

  # Inline code span sized so the content cannot close it.
  def code:
    (. // "") | tostring | gsub("[\r\n]+"; " ") as $s
    | ([$s | scan("`+") | length] | max // 0) as $n
    | ("`" * ($n + 1)) as $f
    | if $s == "" then "" else $f + (if ($s | test("^`|`$")) then " \($s) " else $s end) + $f end;

  # Fenced block sized so the content cannot close it.
  def fenced($lang):
    (. // "") | tostring | rtrimstr("\n") as $s
    | ([$s | scan("`{3,}") | length] | max // 0) as $n
    | ("`" * ([3, $n + 1] | max)) as $f
    | "\($f)\($lang)\n\($s)\n\($f)";

  # Shell word: bare when obviously safe, $'...' for control characters,
  # single quotes otherwise. Output never contains a raw newline.
  def shq:
    tostring
    | if test("^[A-Za-z0-9_@%+=:,./-]+$") then .
      elif test("[[:cntrl:]]") then
        "$'\''" + (gsub("\\\\"; "\\\\") | gsub("'\''"; "\\'\''") | gsub("\n"; "\\n")
                   | gsub("\t"; "\\t") | gsub("\r"; "\\r") | gsub("[[:cntrl:]]"; "")) + "'\''"
      else @sh end;

  # --- links -----------------------------------------------------------------

  def is_sha: type == "string" and test("^[0-9a-fA-F]{7,40}$");
  def clean_path: tostring | ltrimstr("./");
  def safe_path:
    type == "string" and length > 0 and (startswith("/") | not)
    and (test("[[:cntrl:]]") | not) and (split("/") | index("..") | not);
  def safe_url:
    type == "string" and test("^https?://[^\\s<>\"'\''`()\\[\\]]+$");
  def strip_auth: sub("[?&]auth=[^&#]*"; "");
  def commit_md:
    if is_sha and $repo_url != "" then "[\(.[0:7] | code)](\($repo_url)/commit/\(.))"
    elif . == null or . == "" then "-"
    else .[0:12] | code end;
  def permalink($commit; $path; $line):
    if $repo_url != "" and ($commit | is_sha) and ($path | safe_path) then
      "\($repo_url)/blob/\($commit)/\($path | split("/") | map(@uri) | join("/"))"
      + (if ($line | type) == "number" and $line >= 1 then "#L\($line | floor)" else "" end)
    else null end;

  # --- formatting helpers ----------------------------------------------------

  def runs_list: if length == 0 then "none" else map(code) | join(", ") end;
  def created: tostring | if test("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d") then .[0:10] + " " + .[11:16] else text end;
  def dur: if . == null then "?" elif . < 60000 then "\(. / 100 | round / 10)s"
           else "\(. / 60000 | floor)m \((. % 60000) / 1000 | round)s" end;
  def category_label:
    tostring as $k
    | {sut_bug: "SUT bug", workload_bug: "workload bug", setup: "setup", infra: "infrastructure", unknown: "unknown"}[$k] // ($k | text);
  def class_label:
    tostring as $k
    | {new: "New", ongoing: "Ongoing", known_issue: "Known issue", unclear: "Unclear"}[$k] // ($k | text);
  def snouty_line: map(shq) | join(" ") | "snouty " + .;

  # The debugging-session title argument: double quotes when nothing in it
  # is special to the shell, single quotes otherwise.
  def title_arg: if test("^[^\"$`\\\\!]*$") and (test("[[:cntrl:]]") | not) then "\"\(.)\"" else shq end;

  ($f.runs // [] | map(select(.run_id | type == "string") | {key: .run_id, value: .}) | from_entries) as $runs_by_id
  |

  def render_failure($n):
    . as $x
    | ($x.failing_runs // []) as $failing
    | ([$failing[] | $runs_by_id[.].commit // empty | select(is_sha)] | first) as $run_commit
    | [ "### \($n). \($x.classification | class_label): \($x.property | text)",
        "",
        "- **Classification:** \($x.classification | tostring | gsub("_"; " ") | text)"
          + (if ($x.baseline_runs // []) | length > 0
             then " (compared against \($x.baseline_runs | runs_list))"
             else " (no earlier runs in this group to compare against)" end),
        "- **Group:** \($x.run_group | text) · **Rate:** \($x.rate | text)",
        "- **Failing runs:** \($failing | runs_list)",
        "- **Confidence:** \($x.confidence | text) · **Category:** \($x.category | category_label)",
        ( $x.known_issue // empty
          | "- **Known issue:** \(.entry | text) (**\(.status | gsub("_"; " ") | text)**): \(.reason | text)" ),
        "",
        ( if ($x.evidence // []) | length > 0 then
            "#### Evidence", "",
            ( $x.evidence[]
              | ( [ "Run \(.run_id | code)",
                    (.input_hash // empty | "input hash \(code)"),
                    (.vtime // empty | "vtime \(code)"),
                    (.container // empty | "container \(code)") ] | join(" · ") ),
                "",
                (.excerpt | fenced("text")),
                "" )
          else empty end ),
        "#### Root cause", "",
        ($x.root_cause | if . == "" or . == null then "_No hypothesis given._" else md end),
        "",
        ( if ($x.source_refs // []) | length > 0 then
            "**Source references:**", "",
            ( $x.source_refs[]
              | (.path | clean_path) as $p
              | (.commit // $run_commit) as $c
              | ($p + (if (.line | type) == "number" then "#L\(.line)" else "" end)) as $label
              | permalink($c; $p; .line) as $url
              | "- " + (if $url then "[\($label | code)](\($url))" else ($label | code) end)
                + (if ($c | is_sha) then " at \($c[0:7] | code)" else "" end)
                + (if (.note // "") != "" then ": \(.note | text)" else "" end) ),
            ""
          else empty end ),
        "#### Suggested fix", "",
        ($x.suggested_fix | if . == "" or . == null then "_None._" else md end),
        "",
        ( $x.patch_file // empty
          | . as $p
          | "Patch: \(code) in the artifact"
            + (if $patches_present == null or ($patches_present | index([$p])) then "." else " (**missing**: the file was not written)." end),
          "" ),
        ( $x.recommended_debug_session // empty
          | ($x.property | tostring | gsub("[\r\n]+"; " ") | "\(.) \($date)") as $title
          | "#### Recommended debugging session", "",
            "- **Why this moment:** \(.reason | text)",
            "- **What to inspect:** \(.inspect | text)",
            "",
            "Start the session yourself (it uses core hours until it ends; see the `antithesis-debug` skill):",
            "",
            ( [ "snouty debug --run-id \(.run_id | shq) --input-hash \(.input_hash | shq) --vtime \(.vtime | shq) --title \($title | title_arg)",
                "# snouty prints the session'\''s run id. When it is ready, run commands at that moment:",
                "# snouty runs wait <session-run-id> --until ready",
                "# snouty runs exec <session-run-id> \(.input_hash | shq) \(.vtime | shq) --source-run-id \(.run_id | shq) '\''ps aux'\''"
              ] | join("\n") | fenced("sh") ),
            "" ),
        ( if ($x.reproduce_commands // []) | length > 0 then
            "#### Reproduce", "",
            "Commands written by the agent; review them before pasting.", "",
            ($x.reproduce_commands | map(tostring | gsub("[\r\n]+"; " ")) | join("\n") | fenced("sh")),
            ""
          else empty end )
      ] | join("\n");

  ($f.failures // []) as $failures
  | [$failures[] | select(.classification != "known_issue")] as $main
  | ($main | map(select(.classification == "new")) + map(select(.classification == "ongoing"))
     + map(select(.classification != "new" and .classification != "ongoing"))) as $main_sorted
  | [$failures[] | select(.classification == "known_issue")] as $known
  | ($failures | map(select(.known_issue.status == "diverged")) | length) as $diverged
  | ($f.errors // []) as $errors
  | ($cmdlog | split("\n") | map(select(test("\\S"))) | map(try fromjson catch null)) as $cmds_raw
  | [$cmds_raw[] | objects] as $cmds
  | ($cmds_raw | map(select(type != "object")) | length) as $bad_cmd_lines
  | [
      "# Antithesis triage report",
      "",
      ( [ "**Status:** \($f.status | text)",
          (if $repo != "" then "**Repository:** \($repo | code)" else empty end),
          (if $artifact != "" then "**Artifact:** \($artifact | code)" + (if $run_url != "" then " ([workflow run](\($run_url)))" else "" end)
           elif $run_url != "" then "[Workflow run](\($run_url))" else empty end)
        ] | join(" · ") ),
      "",
      ( if $f.status == "failed" then "> **The triage did not complete.** See the errors below; any results shown are incomplete.", ""
        elif $f.status == "partial" then "> **Partial results.** The agent stopped before finishing; some failures may be missing.", ""
        else empty end ),
      ( if ($errors | length) > 0 then
          "**Errors reported:**", "", ($errors[] | "- \(text)"), ""
        else empty end ),
      "## Summary",
      "",
      ($f.summary | if . == "" or . == null then "_No summary._" else md end),
      "",
      ( "**Failures:** \($main | map(select(.classification == "new")) | length) new, "
        + "\($main | map(select(.classification == "ongoing")) | length) ongoing, "
        + "\($main | map(select(.classification != "new" and .classification != "ongoing")) | length) unclear, "
        + "\($known | length) known issues (\($diverged) diverged) · "
        + "**Runs:** \(($f.runs // []) | length) triaged, \(($f.skipped_runs // []) | length) skipped" ),
      "",
      ( [ ($versions.action_ref // empty | "action \(code)"),
          ($versions.snouty // empty | "snouty \(code)"),
          ($versions.claude_code // empty | "Claude Code \(code)"),
          ($versions.skills_ref // empty | "triage skill \(tostring | if is_sha then .[0:12] else . end | code)"),
          ($versions.model // empty | "model \(code)") ] as $v
        | if ($v | length) > 0 then "**Versions:** " + ($v | join(" · ")), "" else empty end ),
      ( $agent // empty
        | "**Agent session:** \(.subtype // "unknown" | text)"
          + (if .num_turns then ", \(.num_turns) turns" else "" end)
          + (if .total_cost_usd then ", about $\(.total_cost_usd * 100 | round / 100) estimated cost" else "" end)
          + (if .duration_ms then ", \(.duration_ms | dur)" else "" end), "" ),
      ( ($inputs // {}) | if type == "object" then to_entries else [] end
        | map(.key |= (ltrimstr("ATT_IN_") | ascii_downcase | gsub("_"; "-"))
              | .value |= (if type == "string" then . else tojson end)
              | select(.value != ""))
        | if length == 0 then "**Inputs:** all defaults.", ""
          else
            "<details><summary>Inputs</summary>", "",
            ( map(if (.value | contains("\n")) then "\(.key): |\n" + (.value | rtrimstr("\n") | split("\n") | map("  " + .) | join("\n"))
                  else "\(.key): \(.value)" end) | join("\n") | fenced("yaml") ),
            "", "</details>", ""
          end ),
      "## Selection and grouping",
      "",
      "**Selection applied** (\($f.selection.runs_considered // 0) runs considered):",
      "",
      ($f.selection.applied | md),
      "",
      "**Grouping applied** (\(if $f.grouping.inferred then "inferred by the agent" else "from the `grouping` input" end)):",
      "",
      ($f.grouping.applied | md),
      "",
      ( if (($f.skipped_runs // []) | length) > 0 then
          "**Skipped runs:**", "", ($f.skipped_runs[] | "- \(.run_id | code): \(.reason | text)"), ""
        else empty end ),
      "## Runs",
      "",
      ( if (($f.runs // []) | length) == 0 then "_No runs were triaged._"
        else
          "| Run | Created | Group | Commit | Status | Failed (new) | Passed | Instrumentation | Report | Notes |",
          "|---|---|---|---|---|---|---|---|---|---|",
          ( $f.runs[] | . as $r
            | ([$main[] | select(.classification == "new" and ((.failing_runs // []) | index([$r.run_id])))] | length) as $new
            | [ ($r.run_id | code),
                ($r.created_at | created),
                ($r.group | text),
                ($r.commit | commit_md),
                ($r.status | text),
                "\($r.properties_failed) (\($new) new)",
                "\($r.properties_passed)",
                (if $r.instrumentation == "ok" then "ok" else "**\($r.instrumentation | text)**" end),
                ($r.triage_report_url | if safe_url then "[triage report](\(strip_auth))" else "-" end),
                ($r.notes | text) ]
            # Escape pipes once per cell (works inside code spans too).
            | "| " + (map(gsub("\\|"; "\\|")) | join(" | ")) + " |" )
        end ),
      "",
      "## Failures",
      "",
      ( if ($main_sorted | length) == 0 then "_No new, ongoing, or unclear failures._", ""
        else ($main_sorted | to_entries[] | (.value | render_failure(.key + 1)), "") end ),
      ( "<details><summary>Known issues: \($known | length) matched (\($diverged) diverged), "
        + "\(($f.known_issues_not_seen // []) | length) not seen</summary>" ),
      "",
      ( if ($known | length) == 0 then "_No failures matched the `known-issues` input._", ""
        else ($known | to_entries[] | (.value | render_failure(.key + 1)), "") end ),
      ( if (($f.known_issues_not_seen // []) | length) > 0 then
          "**Known issues that did not occur in the selected runs:**", "",
          ($f.known_issues_not_seen[] | "- \(text)"), ""
        else empty end ),
      "</details>",
      "",
      "## Run health",
      "",
      ( [ ($f.run_health // [])[] | "- \(text)" ]
        + [ ($f.runs // []) | map(select(.instrumentation != "ok")) | select(length > 0)
            | "- Instrumentation not confirmed for: " + (map("\(.run_id | code) (\(.instrumentation | text))") | join(", ")) ]
        | if length == 0 then "No problems reported." else join("\n") end ),
      "",
      "## Not investigated",
      "",
      ( if (($f.ignored // []) | length) > 0 then
          "**Ignored** (matched the `ignore` input; counted, not investigated):", "",
          ($f.ignored[] | "- \(.entry | text): \(.count)"), ""
        else "Nothing matched the `ignore` input.", "" end ),
      ( if (($f.not_investigated // []) | length) > 0 then
          "**Skipped:**", "",
          ($f.not_investigated[] | "- \(.property | text): \(.reason | text)"), ""
        else empty end ),
      "### Resume this session",
      "",
      ( if $transcripts == "included" then
          "The artifact'\''s `transcript/` folder has the raw Claude Code session log (`claude-session.jsonl`) and a normalized copy (`transcript.jsonl`: OpenAI-chat-shaped messages after a header line with versions and inputs; tool outputs over 16 KB are in `tool-results/`)."
          + (if $sid != "" then " Session id: \($sid | code)." else "" end),
          "",
          "To continue the investigation locally, check out this repository, build the same single-skill plugin directory (`antithesis-triage` from antithesishq/antithesis-skills at "
          + ($versions.skills_ref // "the same ref" | tostring | code)
          + ", laid out as `plugin/.claude-plugin/plugin.json` and `plugin/skills/antithesis-triage/`), then run from the checkout with the same Claude Code version"
          + ($versions.claude_code // empty | " (\(code))") + ":",
          "",
          ( [ "claude --resume \"$PWD/transcript/claude-session.jsonl\" --fork-session --plugin-dir ./plugin"
              + ($versions.model // empty | " --model \(shq)") ] | join("\n") | fenced("sh") ),
          "",
          "`--resume` takes a session id or the path to a session `.jsonl` file; `--fork-session` leaves the downloaded log unchanged. Adjust the paths to where you unpacked the artifact and built the plugin."
        else
          "Transcripts were withheld from this artifact"
          + (if $treason != "" then ": \($treason | text)" else "." end)
          + " Set `upload-transcript: true` to include them; only do that where everyone who can download this workflow'\''s artifacts may see the agent'\''s full tool output. The commands below still reproduce every snouty call the agent made."
        end ),
      "",
      ( "<details><summary>Commands run (\($cmds | length) snouty calls, \($cmds | map(select(.denied == true)) | length) denied)</summary>" ),
      "",
      ( if ($cmds | length) == 0 then "_No snouty calls were logged._"
        else
          "Every snouty call the agent made, in order (denied calls are commented out). Run them with the same `ANTITHESIS_API_KEY` and tenant to reproduce or continue the investigation.",
          "",
          ( $cmds
            | map( (.argv // [] | if type == "array" then . else [.] end
                    | map(tostring)
                    | if length > 0 and (.[0] == "snouty" or (.[0] | endswith("/snouty"))) then .[1:] else . end) as $argv
                   | ($argv | snouty_line) as $line
                   | if .denied == true then "# DENIED: \($line)"
                     else "\($line)  # exit \(.exit // "?"), \(.duration_ms | dur)" end )
            | join("\n") | fenced("sh") )
        end ),
      ( if $bad_cmd_lines > 0 then "", "_\($bad_cmd_lines) unreadable line(s) in commands.log were skipped._" else empty end ),
      "",
      "</details>",
      "",
      "---",
      "",
      "_Generated by antithesis-triage-action. Findings are written by a model from run logs and may be wrong; review before acting._"
    ]
  | join("\n") + "\n"
'

jq -n -r \
  --slurpfile f_doc "$work/findings.json" \
  --slurpfile versions_doc "$work/versions.json" \
  --slurpfile inputs_doc "$work/inputs.json" \
  --slurpfile agent_doc "$work/agent.json" \
  --slurpfile patches_doc "$work/patches.json" \
  --rawfile cmdlog "$cmdlog" \
  --arg repo_url "$repo_url" \
  --arg repo "${GITHUB_REPOSITORY:-}" \
  --arg run_url "$run_url" \
  --arg artifact "$artifact_name" \
  --arg sid "$session_id" \
  --arg transcripts "$transcripts" \
  --arg treason "$transcripts_reason" \
  --arg date "${ATT_REPORT_DATE:-$(date -u +%F)}" \
  "\$f_doc[0] as \$f | \$versions_doc[0] as \$versions | \$inputs_doc[0] as \$inputs
   | \$agent_doc[0] as \$agent | \$patches_doc[0] as \$patches_present | $program" >"$out.tmp"
mv -f "$out.tmp" "$out"
