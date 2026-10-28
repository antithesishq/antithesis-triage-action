#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $ and backticks in expected strings
# Tests for scripts/redact.sh.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/redact.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

ok() { echo "ok - $1"; }
not_ok() { echo "not ok - $1"; fails=$((fails + 1)); }
contains() { grep -rqF -- "$2" "$1"; }

# Secrets full of regex/sed/shell metacharacters.
api_key='ak.*+?[x](y)|^$\/&"q'\''z{2}'
anthropic_key='sk-ant-api03-Zz9_-abcdefghijklmnop'
gh_token='ghs_0123456789abcdefghijABCDEFGHIJxyzw'
aws_secret='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
short='abc'

url_upper=$(jq -rn --arg s "$api_key" '$s | @uri')
url_lower=$(jq -rn --arg s "$api_key" '$s | @uri | gsub("%(?<h>[0-9A-F]{2})"; "%" + (.h | ascii_downcase))')

d=$tmp/out
mkdir -p "$d/transcript/tool-results" "$d/patches"
printf 'raw: %s\nupper: %s\nlower: %s\n' "$api_key" "$url_upper" "$url_lower" >"$d/a.txt"
jq -n --arg k "$api_key" --arg a "$aws_secret" '{key: $k, aws: $a, url: "https://t.antithesis.com/report/abc?auth=v2.public.SIG"}' >"$d/transcript/x.json"
printf '%s' "token $gh_token and $anthropic_key, pat github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz" >"$d/transcript/tool-results/t.txt"
cat >"$d/patches/fix.patch" <<EOF
see https://t.antithesis.com/report/abc?auth=SIGNED&tab=logs and [r](https://x/y?auth=QQQ)
and https://x/z?a=1&auth=ZZZ#frag
literal mention of the \`?auth=\` parameter stays
short: $short
EOF
printf 'bin\0ary %s' "$api_key" >"$d/blob.bin"
cp "$d/blob.bin" "$tmp/blob.orig"
cp "$d/a.txt" "$tmp/a.orig"

out=$(ANTITHESIS_API_KEY=$api_key ANTHROPIC_API_KEY=$anthropic_key GITHUB_TOKEN=$gh_token \
  AWS_SECRET_ACCESS_KEY=$aws_secret ATT_GITHUB_TOKEN=$short AWS_SESSION_TOKEN='' \
  "$script" "$d" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then ok "exit 0"; else not_ok "exit $rc: $out"; fi

if [[ $out == *"$api_key"* || $out == *"$aws_secret"* || $out == *"$gh_token"* ]]; then
  not_ok "secrets printed"
else
  ok "secrets not printed"
fi

text_files=("$d/a.txt" "$d/transcript" "$d/patches")
leak=0
for s in "$api_key" "$url_upper" "$url_lower" "$anthropic_key" "$gh_token" "$aws_secret" "SIG" "SIGNED" "QQQ" "ZZZ" "github_pat_11"; do
  for f in "${text_files[@]}"; do
    if contains "$f" "$s"; then not_ok "leaked '$s' in $f"; leak=1; fi
  done
done
[[ $leak -eq 0 ]] && ok "no secret, URL-encoded secret, token or auth signature left"

if grep -c '\[REDACTED:ANTITHESIS_API_KEY\]' "$d/a.txt" | grep -qx 3; then ok "raw and URL-encoded forms replaced with a marker"; else not_ok "markers: $(cat "$d/a.txt")"; fi

if jq -e '.key == "[REDACTED:ANTITHESIS_API_KEY]" and .aws == "[REDACTED:AWS_SECRET_ACCESS_KEY]" and .url == "https://t.antithesis.com/report/abc"' "$d/transcript/x.json" >/dev/null; then
  ok "JSON-escaped secret redacted and file still valid JSON"
else
  not_ok "JSON redaction: $(cat "$d/transcript/x.json")"
fi

expected_patch='see https://t.antithesis.com/report/abc?tab=logs and [r](https://x/y)
and https://x/z?a=1#frag
literal mention of the `?auth=` parameter stays
short: abc'
if [[ $(cat "$d/patches/fix.patch") == "$expected_patch" ]]; then ok "auth query strings stripped, URLs kept"; else not_ok "patch: $(cat "$d/patches/fix.patch")"; fi

if [[ $out == *"ATT_GITHUB_TOKEN is set but shorter than 8 characters"* ]]; then ok "short secret warned"; else not_ok "short secret warning missing: $out"; fi

t=$(cat "$d/transcript/tool-results/t.txt")
if [[ $t == "token [REDACTED:GITHUB_TOKEN] and [REDACTED:ANTHROPIC_API_KEY], pat [REDACTED:github-token]" ]]; then
  ok "token patterns redacted"
else
  not_ok "tokens: $t"
fi
if [[ -z $(tail -c 1 "$d/transcript/tool-results/t.txt") ]]; then not_ok "added a trailing newline"; else ok "missing trailing newline preserved"; fi
if [[ -n $(tail -c 1 "$d/a.txt") ]]; then not_ok "dropped a trailing newline"; else ok "trailing newline preserved"; fi

if cmp -s "$d/blob.bin" "$tmp/blob.orig" && [[ $out == *"skipped binary file"* ]]; then ok "binary file skipped with a warning"; else not_ok "binary handling: $out"; fi

# Unset secrets: nothing to replace but patterns still apply; single files work.
printf 'plain text, nothing secret\n' >"$tmp/plain.txt"
cp "$tmp/plain.txt" "$tmp/plain.orig"
env -u ANTITHESIS_API_KEY -u ANTHROPIC_API_KEY -u GITHUB_TOKEN "$script" "$tmp/plain.txt" >/dev/null 2>&1
if cmp -s "$tmp/plain.txt" "$tmp/plain.orig"; then ok "unchanged file left alone"; else not_ok "plain file modified"; fi

if "$script" >/dev/null 2>&1; then not_ok "no args should fail"; else ok "usage error without args"; fi

[[ $fails -eq 0 ]]
