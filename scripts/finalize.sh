#!/usr/bin/env bash
# Finalize the triage run (runs with `if: always()`): make sure a valid
# findings.json exists, collect transcripts if enabled, redact the artifact,
# render report.md, write the job summary and step outputs, and pick the exit
# code. Tolerates any earlier step having failed, including ATT_OUT unset.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
action_path=${ATT_ACTION_PATH:-$(dirname "$here")}
schema=$action_path/schema/findings.schema.json
outcome=${ATT_AGENT_OUTCOME:-}
summary_limit=$((1024 * 1024 - 8192)) # job summaries are capped at 1 MiB

set_output() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}
append_summary() {
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi
}
exit_code_for() {
  if [[ $outcome != success || $1 == failed ]]; then echo 1; else echo 0; fi
}

if [[ -z ${ATT_OUT:-} ]]; then
  echo "::error::Antithesis triage did not get far enough to produce a report (setup failed; agent step: ${outcome:-not run})."
  printf '%s\n' "**Antithesis triage failed** before producing a report: setup did not complete (agent step: ${outcome:-not run}). See the job log." | append_summary
  set_output status failed
  exit 1
fi

# If anything below fails unexpectedly, still report a status.
trap 'set_output status failed' ERR

out=$ATT_OUT
work=${ATT_WORK:-${ATT_HOME:-$(dirname "$out")}/work}
findings=$out/findings.json
report=$out/report.md
mkdir -p "$out"

# --- 1. findings.json: present, valid, final status ---------------------------
echo "::group::Finalize: findings.json"
agent_note=''
if [[ $outcome != success ]]; then
  subtype=$(jq -r '.subtype // empty' "$work/agent-result.json" 2>/dev/null || true)
  agent_note="The agent step did not succeed (outcome: ${outcome:-unknown}${subtype:+, result: $subtype})."
fi

write_minimal() { # errors...
  jq -n '{
    schema_version: "0.1", status: "failed",
    summary: "The triage agent did not produce a valid findings.json, so there are no results. See the errors below and the job log.",
    selection: {applied: "", runs_considered: 0}, grouping: {applied: "", inferred: true},
    runs: [], skipped_runs: [], failures: [], known_issues_not_seen: [], ignored: [],
    not_investigated: [], run_health: [], errors: $ARGS.positional
  }' --args "$@" >"$findings"
}

if [[ ! -s $findings ]]; then
  if [[ -e $findings ]]; then mv -f "$findings" "$out/findings.invalid.json"; fi
  echo "::error::findings.json was not written by the agent."
  write_minimal "findings.json was not written by the agent." ${agent_note:+"$agent_note"}
elif ! violations=$("$here/validate-findings.sh" "$findings" "$schema"); then
  mv -f "$findings" "$out/findings.invalid.json"
  # Details go to the (redacted) report rather than the log: they quote values.
  count=$(printf '%s\n' "$violations" | wc -l)
  echo "::error::findings.json does not match the schema ($count problems, listed in the report); kept as findings.invalid.json."
  mapfile -t first < <(printf '%s\n' "$violations" | head -n 20 | sed 's/^/schema: /')
  if [[ $count -gt 20 ]]; then first+=("schema: ... and $((count - 20)) more."); fi
  write_minimal "findings.json did not match the schema; the agent's file is kept as findings.invalid.json in the artifact." \
    "${first[@]}" ${agent_note:+"$agent_note"}
else
  current=$(jq -r .status "$findings")
  if [[ $current == in_progress ]]; then
    note=${agent_note:-"The agent finished without marking findings.json complete."}
    jq --arg note "$note" '.status = "partial" | .errors += [$note]' "$findings" >"$findings.tmp"
    mv -f "$findings.tmp" "$findings"
  elif [[ -n $agent_note ]]; then
    jq --arg note "$agent_note" '.errors += [$note]' "$findings" >"$findings.tmp"
    mv -f "$findings.tmp" "$findings"
  fi
fi

# --- 2. validate the final file ----------------------------------------------
if ! "$here/validate-findings.sh" "$findings" "$schema"; then
  echo "::error::internal: the final findings.json does not match the schema."
fi
status=$(jq -r '.status // "failed"' "$findings" 2>/dev/null || echo failed)
echo "status: $status"
echo "::endgroup::"

# --- 3. transcripts on or off -------------------------------------------------
echo "::group::Finalize: transcripts"
repo_visibility() { # prints private|public|unknown
  local api=${GITHUB_API_URL:-https://api.github.com} resp
  if [[ -z ${GITHUB_REPOSITORY:-} ]]; then echo unknown; return; fi
  # Headers (and the token) go to curl on stdin, not argv.
  if ! resp=$(
    {
      printf 'Accept: application/vnd.github+json\n'
      if [[ -n ${ATT_GITHUB_TOKEN:-} ]]; then printf 'Authorization: Bearer %s\n' "$ATT_GITHUB_TOKEN"; fi
    } | curl -fsS --max-time 15 --retry 2 -H @- "$api/repos/$GITHUB_REPOSITORY" 2>/dev/null
  ); then
    echo unknown
    return
  fi
  case $(jq -r '.private' <<<"$resp" 2>/dev/null) in
    true) echo private ;;
    false) echo public ;;
    *) echo unknown ;;
  esac
}

transcripts=withheld
transcripts_reason=''
mode=$(tr '[:upper:]' '[:lower:]' <<<"${ATT_UPLOAD_TRANSCRIPT:-auto}")
case $mode in
  true | yes | on | 1) transcripts=included ;;
  false | no | off | 0) transcripts_reason="upload-transcript is false." ;;
  *)
    if [[ $mode != auto ]]; then
      echo "::warning::upload-transcript '${ATT_UPLOAD_TRANSCRIPT}' is not true, false or auto; treating it as auto."
    fi
    case $(repo_visibility) in
      private) transcripts=included ;;
      public) transcripts_reason="upload-transcript is auto and the repository is public." ;;
      *) transcripts_reason="upload-transcript is auto and the repository's visibility could not be determined." ;;
    esac
    ;;
esac

# --- 4. collect transcripts ---------------------------------------------------
session_id=$(tr -d '[:space:]' 2>/dev/null <"$work/session-id" || true)
if [[ ! $session_id =~ ^[A-Za-z0-9_-]+$ ]]; then session_id=''; fi
tdir=$out/transcript
rm -rf "$tdir"
if [[ $transcripts == included ]]; then
  mkdir -p "$tdir"
  config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  session_log=''
  if [[ -n $session_id && -d $config_dir/projects ]]; then
    session_log=$(find "$config_dir/projects" -mindepth 2 -maxdepth 2 -type f -name "$session_id.jsonl" 2>/dev/null | head -n 1)
  fi
  if [[ -n $session_log ]]; then
    cp "$session_log" "$tdir/claude-session.jsonl"
    # Newer Claude Code keeps large tool outputs/subagents next to the log.
    if [[ -d ${session_log%.jsonl} ]]; then cp -R "${session_log%.jsonl}" "$tdir/claude-session"; fi
  else
    echo "::warning::Claude Code session log not found (session id: ${session_id:-unknown})."
  fi
  if [[ -s $work/stream.jsonl ]]; then
    if ! "$here/normalize-transcript.sh" "$work/stream.jsonl" "$tdir" \
      --versions "$work/versions.json" --inputs "$work/inputs.json" \
      --session-id "$session_id" --prompt "$work/prompt.md"; then
      echo "::warning::Could not normalize the agent's stream output."
    fi
  else
    echo "::warning::No agent stream output (stream.jsonl) to normalize."
  fi
  if [[ -z $(ls -A "$tdir") ]]; then
    rmdir "$tdir"
    transcripts=withheld
    transcripts_reason="no session log or agent output was found."
  fi
fi
echo "transcripts: $transcripts${transcripts_reason:+ ($transcripts_reason)}"
echo "::endgroup::"

# --- 5. redact ----------------------------------------------------------------
echo "::group::Finalize: redact"
# The artifact holds regular files only.
while IFS= read -r -d '' link; do
  echo "::warning::Removing symlink from the artifact: ${link#"$out"/}"
  rm -f "$link"
done < <(find "$out" -type l -print0)
if ! "$here/redact.sh" "$out"; then
  # Never upload what could not be redacted: move it out of the artifact.
  echo "::error::Redaction failed; removing the agent's files from the artifact."
  quarantine=$work/unredacted-$(date +%s)
  mkdir -p "$quarantine"
  find "$out" -mindepth 1 -maxdepth 1 -exec mv -t "$quarantine" {} +
  write_minimal "Redaction of the output failed, so the agent's files were removed from the artifact." ${agent_note:+"$agent_note"}
  status=failed
  transcripts=withheld
  transcripts_reason="redaction failed."
fi
echo "::endgroup::"

# --- 6. report.md ---------------------------------------------------------------
echo "::group::Finalize: report"
if ! "$here/render-report.sh" --findings "$findings" --out "$report" \
  --commands-log "${ATT_COMMANDS_LOG:-$out/commands.log}" \
  --versions "$work/versions.json" --inputs "$work/inputs.json" \
  --agent-result "$work/agent-result.json" --artifact-dir "$out" \
  --session-id "$session_id" --transcripts "$transcripts" \
  --transcripts-reason "$transcripts_reason"; then
  echo "::error::Rendering report.md failed; writing a minimal report."
  printf '# Antithesis triage report\n\n**Status:** %s\n\nThe report could not be rendered. See findings.json in the artifact and the job log.\n' \
    "$status" >"$report"
fi
# The report also embeds inputs/versions from outside the artifact dir.
"$here/redact.sh" "$report" || {
  echo "::error::Redacting report.md failed."
  printf '# Antithesis triage report\n\n**Status:** %s\n\nThe report was withheld because redaction failed.\n' "$status" >"$report"
}
echo "::endgroup::"

# --- 7. job summary -----------------------------------------------------------
artifact_note="the artifact"
if [[ -n ${GITHUB_RUN_NUMBER:-} ]]; then
  artifact_note="the artifact \`antithesis-triage-$GITHUB_RUN_NUMBER-${GITHUB_RUN_ATTEMPT:-1}\`"
fi
if [[ -n ${GITHUB_SERVER_URL:-} && -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_RUN_ID:-} ]]; then
  artifact_note+=" on the [workflow run page](${GITHUB_SERVER_URL%/}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)"
fi
# shellcheck disable=SC2016  # jq program, not shell
close_blocks='
  # Drop the last (possibly cut) line, then close any code fence or
  # <details> the cut left open so the note below renders normally.
  split("\n") | .[:-1] | . as $lines
  | (reduce .[] as $l ({fence: null, details: 0};
      if .fence == null then
        ([$l | capture("^ {0,3}(?<f>`{3,}|~{3,})")][0]) as $m
        | if $m then .fence = {c: $m.f[0:1], n: ($m.f | length)}
          else .details += ([$l | scan("<details[ >]")] | length) - ([$l | scan("</details>")] | length) end
      else
        .fence as $fe
        | if ($l | test("^ {0,3}" + $fe.c + "{\($fe.n),}[ \t]*$")) then .fence = null else . end
      end)) as $st
  | ($lines | join("\n")) + "\n"
    + (if $st.fence then ($st.fence.c * $st.fence.n) + "\n" else "" end)
    + ([range(0; [$st.details, 0] | max)] | map("\n</details>\n") | join(""))
'
write_summary() {
  if [[ $(wc -c <"$report") -le $summary_limit ]]; then
    append_summary <"$report"
  else
    {
      head -c "$((summary_limit - 1024))" "$report" | jq -Rrs -j "$close_blocks"
      # shellcheck disable=SC2016  # markdown backticks, not a command substitution
      printf '\n---\n\n**This report was truncated to fit the job summary.** The full report is `report.md` in %s.\n' "$artifact_note"
    } | append_summary
  fi
}
if ! write_summary; then
  echo "::warning::Could not write the job summary."
fi

# --- 8. outputs -----------------------------------------------------------------
set_output status "$status"
set_output report-path "$report"
set_output findings-path "$findings"

# --- 9. exit code ---------------------------------------------------------------
code=$(exit_code_for "$status")
if [[ $code != 0 ]]; then
  echo "::error::Antithesis triage finished with status '$status' (agent step: ${outcome:-unknown})."
else
  echo "::notice::Antithesis triage finished with status '$status'."
fi
exit "$code"
