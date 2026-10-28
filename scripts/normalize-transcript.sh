#!/usr/bin/env bash
# Convert Claude Code `--output-format stream-json --verbose` output into an
# OpenAI-chat-shaped transcript.
#
# Usage: normalize-transcript.sh <stream.jsonl> <out-dir>
#          [--versions versions.json] [--inputs inputs.json]
#          [--session-id ID] [--prompt prompt.md]
#
# Writes <out-dir>/transcript.jsonl:
#   line 1: {"type":"header", versions, inputs, session_id, model, ...}
#   then one message per line: {role, content, tool_calls?, tool_call_id?}
#     system    <- system/init (session metadata) and system/compact_boundary
#     user      <- the prompt (if --prompt) and user text blocks
#     assistant <- assistant lines; consecutive lines sharing message.id are
#                  merged; thinking -> reasoning_content, tool_use -> tool_calls
#     tool      <- tool_result blocks (is_error: true kept when set)
# Tool results larger than 16 KiB go to <out-dir>/tool-results/<id>.txt and
# the message content becomes a pointer plus a short preview.
# Unparseable lines (e.g. a line cut off by a timeout) and other line types
# (stream_event, rate_limit_event, hook/status/task events, ...) are skipped.
set -euo pipefail

usage() {
  echo "usage: $0 <stream.jsonl> <out-dir> [--versions F] [--inputs F] [--session-id ID] [--prompt F]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
stream=$1 outdir=$2
shift 2
versions='' inputs='' session_id='' prompt=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --versions) versions=$2 ;;
    --inputs) inputs=$2 ;;
    --session-id) session_id=$2 ;;
    --prompt) prompt=$2 ;;
    *) usage ;;
  esac
  shift 2
done

if [[ ! -f $stream ]]; then
  echo "normalize-transcript: no such file: $stream" >&2
  exit 1
fi

spill_limit=16384
preview_chars=1000

mkdir -p "$outdir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Copy an optional JSON file to $work/<name>.json, or write null if it is
# missing/invalid (files, not argv: argv strings are capped at 128 KiB).
load_json() {
  if [[ -n $2 && -s $2 ]] && jq -e . "$2" >/dev/null 2>&1; then
    jq -c . "$2" >"$work/$1.json"
  else
    echo null >"$work/$1.json"
  fi
}
load_json versions "$versions"
load_json inputs "$inputs"

prompt_text_file=$work/prompt.json
if [[ -n $prompt && -f $prompt ]]; then
  jq -Rs . "$prompt" >"$prompt_text_file"
else
  echo null >"$prompt_text_file"
fi

# shellcheck disable=SC2016  # jq program, not shell
program='
  def text_of:
    if type == "string" then .
    elif type == "array" then
      map(if .type == "text" then .text
          elif .type == "image" then "[image omitted]"
          else "[\(.type // "unknown") block omitted]" end) | join("\n")
    elif . == null then ""
    else tojson end;

  def with_parent($line): if $line.parent_tool_use_id then .parent_tool_use_id = $line.parent_tool_use_id else . end;

  # One stream-json line -> zero or more normalized messages.
  def messages:
    . as $line
    | if .type == "system" and .subtype == "init" then
        { role: "system",
          content: "Claude Code \(.claude_code_version // "?") session \(.session_id // "?") in \(.cwd // "?"), model \(.model // "?"), permission mode \(.permissionMode // "?"). Tools: \((.tools // []) | join(", ")). Skills: \((.skills // []) | join(", ")). Plugins: \((.plugins // []) | map(.name) | join(", "))." }
      elif .type == "system" and .subtype == "compact_boundary" then
        { role: "system",
          content: "[Conversation compacted (\(.compact_metadata.trigger // "?"); \(.compact_metadata.pre_tokens // "?") tokens before).]" }
      elif .type == "assistant" and (.message | type) == "object" then
        (.message.content // [] | if type == "string" then [{type: "text", text: .}] else . end) as $c
        | { role: "assistant", _mid: .message.id,
            content: ([$c[] | select(.type == "text") | .text] | join("\n\n")),
            reasoning_content: ([$c[] | select(.type == "thinking") | .thinking // "" | select(. != "")] | join("\n\n")),
            tool_calls: [$c[] | select(.type == "tool_use" or .type == "server_tool_use")
                         | {id, type: "function", function: {name, arguments: (.input // {} | tojson)}}] }
        | with_parent($line)
      elif .type == "user" and (.message | type) == "object" then
        .message.content as $c
        | if ($c | type) == "string" then {role: "user", content: $c} | with_parent($line)
          elif ($c | type) == "array" then
            ( $c[] | select(.type == "tool_result")
              | {role: "tool", tool_call_id: .tool_use_id, content: (.content | text_of)}
                + (if .is_error == true then {is_error: true} else {} end)
                | with_parent($line) ),
            ( [$c[] | select(.type != "tool_result")] | select(length > 0)
              | {role: "user", content: text_of} | with_parent($line) )
          else empty end
      else empty end;

  [inputs | (try fromjson catch null) | select(type == "object")] as $lines
  | ($lines | map(select(.type == "system" and .subtype == "init")) | first) as $init
  | ($lines | map(select(.type == "result")) | last) as $result
  | $prompt_doc[0] as $prompt | $versions_doc[0] as $versions | $inputs_doc[0] as $inputs
  | [$lines[] | messages]
  | reduce .[] as $m ([];
      if $m.role == "assistant" and length > 0 and .[length - 1].role == "assistant"
         and $m._mid != null and .[length - 1]._mid == $m._mid
      then .[length - 1] |= (
             .content = ([.content, $m.content] | map(select(. != "")) | join("\n\n"))
             | .reasoning_content = ([.reasoning_content, $m.reasoning_content] | map(select(. != "")) | join("\n\n"))
             | .tool_calls += $m.tool_calls)
      else . + [$m] end)
  | map(del(._mid)
        | if .role == "assistant" then
            (if .reasoning_content == "" then del(.reasoning_content) else . end)
            | (if .tool_calls == [] then del(.tool_calls)
               elif .content == "" then .content = null else . end)
          else . end)
  | (if $prompt == null then .
     elif length > 0 and .[0].role == "system" then [.[0], {role: "user", content: $prompt}] + .[1:]
     else [{role: "user", content: $prompt}] + . end) as $msgs
  | { type: "header",
      format: "openai-chat",
      generator: "antithesis-triage-action/normalize-transcript",
      session_id: (if $sid != "" then $sid else ($init.session_id // $result.session_id) end),
      model: ($versions.model // $init.model),
      claude_code_version: ($init.claude_code_version // $versions.claude_code),
      cwd: $init.cwd,
      versions: $versions,
      inputs: $inputs,
      result: (if $result then $result | {subtype, is_error, num_turns, duration_ms, total_cost_usd, stop_reason, terminal_reason, permission_denials: ((.permission_denials // []) | length)} else null end),
      message_count: ($msgs | length),
      tool_result_spill_bytes: $limit },
    $msgs[]
'

jq -nR -c \
  --slurpfile versions_doc "$work/versions.json" \
  --slurpfile inputs_doc "$work/inputs.json" \
  --arg sid "$session_id" \
  --argjson limit "$spill_limit" \
  --slurpfile prompt_doc "$prompt_text_file" \
  "$program" <"$stream" >"$work/all.jsonl"

# Spill large tool results.
# shellcheck disable=SC2016
safe_name='(.tool_call_id // "unknown" | tostring | gsub("[^A-Za-z0-9_-]"; "_"))'
mkdir -p "$outdir/tool-results"
jq -r --argjson limit "$spill_limit" \
  "select(.role == \"tool\" and (.content | utf8bytelength) > \$limit) | [$safe_name, (.content | @base64)] | @tsv" \
  "$work/all.jsonl" |
  while IFS=$'\t' read -r name b64; do
    printf '%s' "$b64" | base64 -d >"$outdir/tool-results/$name.txt"
  done
rmdir "$outdir/tool-results" 2>/dev/null || true

jq -c --argjson limit "$spill_limit" --argjson preview "$preview_chars" "
  if .role == \"tool\" and (.content | utf8bytelength) > \$limit then
    .content = \"[Tool result is \\(.content | utf8bytelength) bytes; full text in tool-results/\\($safe_name).txt. First \\(\$preview) characters:]\\n\" + .content[0:\$preview]
  else . end" "$work/all.jsonl" >"$outdir/transcript.jsonl"
