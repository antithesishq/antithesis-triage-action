#!/usr/bin/env bash
# Redact secrets in place in every file under the given files/directories.
#
# Usage: redact.sh [--quarantine DIR] <dir-or-file>...
#
# Removes:
#   - exact values (and URL-/JSON-escaped forms) of the secret env vars below,
#     when set and at least 8 characters long;
#   - signed "?auth=..." / "&auth=..." query strings (the URL before them stays);
#   - GitHub tokens (ghp_/gho_/ghs_/ghu_/ghr_..., github_pat_...);
#   - Anthropic keys (sk-ant-...);
#   - PEM private key blocks (also unterminated ones, and inside JSON strings).
# Secret values are read by jq from its environment, so they never appear in
# argv, are never printed, and are matched literally (no regex/sed quoting).
#
# Fails closed: a file that can't be redacted as text (it contains NUL bytes,
# or jq fails on it) is moved to the quarantine DIR, keeping its path relative
# to the target, and listed in DIR/quarantined.tsv as "<path>\t<reason>".
# Without --quarantine such a file makes the script exit 1.
set -euo pipefail

usage() {
  echo "usage: $0 [--quarantine DIR] <dir-or-file>..." >&2
  exit 2
}
quarantine=''
if [[ ${1:-} == --quarantine ]]; then
  [[ $# -ge 2 ]] || usage
  quarantine=$2
  shift 2
fi
[[ $# -ge 1 ]] || usage

secret_vars=(ANTITHESIS_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_FOUNDRY_API_KEY
  CLAUDE_CODE_OAUTH_TOKEN AWS_BEARER_TOKEN_BEDROCK AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  ATT_GITHUB_TOKEN GITHUB_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_RUNTIME_TOKEN)

names_json=$(printf '%s\n' "${secret_vars[@]}" | jq -R . | jq -cs .)
for v in "${secret_vars[@]}"; do
  val=${!v:-}
  if [[ -n $val && ${#val} -lt 8 ]]; then
    echo "::warning::redact: $v is set but shorter than 8 characters; not redacting its value" >&2
  fi
done
unset val

# Per line: secrets, auth query strings, token patterns.
# shellcheck disable=SC2016  # jq program, not shell
line_program='
  # Literal forms a secret may take in our files, longest first.
  def forms:
    [ ., @uri, (@uri | gsub("%(?<h>[0-9A-F]{2})"; "%" + (.h | ascii_downcase))),
      (tojson | .[1:-1]), (tojson | .[1:-1] | gsub("/"; "\\/")) ]
    | unique;
  ( [ $names[] as $n | ($ENV[$n] // "") | select(length >= 8)
      | forms[] | {from: ., to: "[REDACTED:\($n)]"} ]
    | sort_by(-(.from | length)) ) as $pairs
  | reduce $pairs[] as $p (.; if contains($p.from) then split($p.from) | join($p.to) else . end)
  | if test("[?&]auth=") then
      gsub("\\?auth=[^\\s\"'"'"'<>&#)\\]`\\\\]+&"; "?")
      | gsub("[?&]auth=[^\\s\"'"'"'<>&#)\\]`\\\\]+"; "")
    else . end
  | if test("gh[pousr]_|github_pat_") then
      gsub("gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"; "[REDACTED:github-token]")
    else . end
  | if contains("sk-ant-") then gsub("sk-ant-[A-Za-z0-9_-]{8,}"; "[REDACTED:anthropic-key]") else . end
'

# Whole file: PEM private keys span lines (or \n escapes inside JSON). An
# unterminated block is cut from BEGIN through the base64 that follows; only
# \n \r \t \/ escapes are consumed so JSON strings stay valid.
# shellcheck disable=SC2016
pem_program='
  "-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----" as $begin
  | gsub($begin + "[\\s\\S]*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----"; "[REDACTED:private-key]")
  | gsub($begin + "(?:[A-Za-z0-9+/=\\s:,.-]|\\\\[nrt/])*"; "[REDACTED:private-key]")
'

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# quarantine_file <file> <path relative to its target> <reason>
quarantine_file() {
  local f=$1 rel=$2 reason=$3
  if [[ -z $quarantine ]]; then
    echo "::error::redact: cannot redact ${rel} (${reason})" >&2
    return 1
  fi
  mkdir -p "$quarantine/$(dirname "$rel")"
  mv -f "$f" "$quarantine/$rel"
  printf '%s\t%s\n' "$rel" "$reason" >>"$quarantine/quarantined.tsv"
  echo "::warning::redact: moved ${rel} out of the artifact (${reason})" >&2
}

redact_file() { # <file> <path relative to its target>
  local f=$1 rel=$2 src tmp=$scratch/out
  [[ -s $f ]] || return 0
  # In the C locale grep -I treats exactly the files with NUL bytes as binary.
  if ! LC_ALL=C grep -Iq '' "$f"; then
    quarantine_file "$f" "$rel" "contains NUL bytes, so it can't be redacted as text"
    return
  fi
  src=$f
  if grep -q 'PRIVATE KEY-----' "$f"; then
    # The PEM pass reads the whole file into memory; quarantine huge files
    # rather than risk running finalize out of memory.
    if [[ $(stat -c %s "$f") -gt $((64 * 1024 * 1024)) ]]; then
      quarantine_file "$f" "$rel" "contains a private key marker and is too large to redact"
      return
    fi
    if ! jq -R -s -j "$pem_program" "$f" >"$scratch/pem"; then
      quarantine_file "$f" "$rel" "redaction failed"
      return
    fi
    src=$scratch/pem
  fi
  if ! jq -R -r --argjson names "$names_json" "$line_program" "$src" >"$tmp"; then
    quarantine_file "$f" "$rel" "redaction failed"
    return
  fi
  # jq -r ends every line with \n; keep a missing final newline missing.
  if [[ -n $(tail -c 1 "$src") ]]; then
    truncate -s -1 "$tmp"
  fi
  if ! cmp -s "$f" "$tmp"; then
    cat "$tmp" >"$f"
  fi
}

status=0
for target in "$@"; do
  if [[ -d $target ]]; then
    while IFS= read -r -d '' f; do
      redact_file "$f" "${f#"${target%/}"/}" || status=1
    done < <(find "$target" -type f -print0)
  elif [[ -f $target ]]; then
    redact_file "$target" "$(basename "$target")" || status=1
  else
    echo "::warning::redact: no such file or directory: ${target}" >&2
  fi
done
exit "$status"
