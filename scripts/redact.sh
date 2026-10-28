#!/usr/bin/env bash
# Redact secrets in place in every text file under the given files/directories.
#
# Usage: redact.sh <dir-or-file>...
#
# Removes:
#   - exact values (and URL-/JSON-escaped forms) of the secret env vars below,
#     when set and at least 8 characters long;
#   - signed "?auth=..." / "&auth=..." query strings (the URL before them stays);
#   - GitHub tokens (ghp_/gho_/ghs_/ghu_/ghr_..., github_pat_...);
#   - Anthropic keys (sk-ant-...).
# Secret values are read by jq from its environment, so they never appear in
# argv, are never printed, and are matched literally (no regex/sed quoting).
# Binary files (containing NUL bytes) are skipped with a warning.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <dir-or-file>..." >&2
  exit 2
fi

secret_vars=(ANTITHESIS_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
  ATT_GITHUB_TOKEN GITHUB_TOKEN AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

names_json=$(printf '%s\n' "${secret_vars[@]}" | jq -R . | jq -cs .)
for v in "${secret_vars[@]}"; do
  val=${!v:-}
  if [[ -n $val && ${#val} -lt 8 ]]; then
    echo "::warning::redact: $v is set but shorter than 8 characters; not redacting its value" >&2
  fi
done
unset val

# shellcheck disable=SC2016  # jq program, not shell
program='
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

redact_file() {
  local f=$1 tmp
  [[ -s $f ]] || return 0
  if ! LC_ALL=C grep -Iq '' "$f"; then
    echo "::warning::redact: skipped binary file ${f}" >&2
    return 0
  fi
  tmp=$(mktemp "${f}.redact.XXXXXX")
  if ! jq -R -r --argjson names "$names_json" "$program" "$f" >"$tmp"; then
    rm -f "$tmp"
    echo "::error::redact: failed to process ${f}" >&2
    return 1
  fi
  # jq -r ends every line with \n; keep a missing final newline missing.
  if [[ -n $(tail -c 1 "$f") ]]; then
    truncate -s -1 "$tmp"
  fi
  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
  else
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
  fi
}

status=0
for target in "$@"; do
  if [[ -d $target ]]; then
    while IFS= read -r -d '' f; do
      redact_file "$f" || status=1
    done < <(find "$target" -type f ! -name '*.redact.??????' -print0)
  elif [[ -f $target ]]; then
    redact_file "$target" || status=1
  else
    echo "::warning::redact: no such file or directory: ${target}" >&2
  fi
done
exit "$status"
