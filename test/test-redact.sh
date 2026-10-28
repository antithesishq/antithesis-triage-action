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
bedrock='ABSKQmVkcm9ja0FQSUtleS1leGFtcGxlLTAxMjM0NTY3ODk='
short='abc'

url_upper=$(jq -rn --arg s "$api_key" '$s | @uri')
url_lower=$(jq -rn --arg s "$api_key" '$s | @uri | gsub("%(?<h>[0-9A-F]{2})"; "%" + (.h | ascii_downcase))')

d=$tmp/out
mkdir -p "$d/transcript/tool-results" "$d/patches/sub"
printf 'raw: %s\nupper: %s\nlower: %s\n' "$api_key" "$url_upper" "$url_lower" >"$d/a.txt"
jq -n --arg k "$api_key" --arg a "$aws_secret" '{key: $k, aws: $a, url: "https://t.antithesis.com/report/abc?auth=v2.public.SIG"}' >"$d/transcript/x.json"
printf '%s' "token $gh_token and $anthropic_key, pat github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz" >"$d/transcript/tool-results/t.txt"
cat >"$d/patches/fix.patch" <<EOF
see https://t.antithesis.com/report/abc?auth=SIGNED&tab=logs and [r](https://x/y?auth=QQQ)
and https://x/z?a=1&auth=ZZZ#frag
literal mention of the \`?auth=\` parameter stays
short: $short
EOF
printf 'patch\0 %s' "$api_key" >"$d/patches/sub/nul.patch"
printf 'bedrock token %s\n' "$bedrock" >"$d/bedrock.txt"
# PEM keys: multi-line, JSON-escaped, and cut off (no END line).
cat >"$d/key.txt" <<'PEM'
before
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MaRcmVDdsQXJMCaM
p8Nbt0PvdPCWcgN0Q4eGJ6sKZ7+0XQ0rlQ==
-----END RSA PRIVATE KEY-----
after
PEM
jq -nc '{text: "key:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----\ndone", cut: "x -----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\nMIIEvQ"}' >"$d/transcript/pem.jsonl"

out=$(ANTITHESIS_API_KEY=$api_key ANTHROPIC_API_KEY=$anthropic_key GITHUB_TOKEN=$gh_token \
  AWS_SECRET_ACCESS_KEY=$aws_secret ATT_GITHUB_TOKEN=$short AWS_SESSION_TOKEN="" AWS_BEARER_TOKEN_BEDROCK=$bedrock \
  "$script" --quarantine "$tmp/q" "$d" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then ok "exit 0"; else not_ok "exit $rc: $out"; fi

if [[ $out == *"$api_key"* || $out == *"$aws_secret"* || $out == *"$gh_token"* || $out == *"$bedrock"* ]]; then
  not_ok "secrets printed"
else
  ok "secrets not printed"
fi

leak=0
for s in "$api_key" "$url_upper" "$url_lower" "$anthropic_key" "$gh_token" "$aws_secret" "$bedrock" \
  "SIG" "SIGNED" "QQQ" "ZZZ" "github_pat_11" "MIIE" "b3BlbnNzaC"; do
  if contains "$d" "$s"; then not_ok "leaked '$s' in $(grep -rlF -- "$s" "$d")"; leak=1; fi
done
[[ $leak -eq 0 ]] && ok "no secret, encoded secret, token, key or auth signature left"

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

if grep -qx 'bedrock token \[REDACTED:AWS_BEARER_TOKEN_BEDROCK\]' "$d/bedrock.txt"; then ok "Bedrock bearer token redacted"; else not_ok "bedrock: $(cat "$d/bedrock.txt")"; fi
if [[ $(cat "$d/key.txt") == $'before\n[REDACTED:private-key]\nafter' ]]; then ok "PEM block redacted"; else not_ok "pem: $(cat "$d/key.txt")"; fi
if jq -e '.text == "key:\n[REDACTED:private-key]\ndone" and .cut == "x [REDACTED:private-key]"' "$d/transcript/pem.jsonl" >/dev/null; then
  ok "PEM in JSON (complete and cut off) redacted, JSON still valid"
else
  not_ok "pem json: $(cat "$d/transcript/pem.jsonl")"
fi

# Files with NUL bytes can't be redacted as text: they leave the tree (fail closed).
if [[ ! -e $d/patches/sub/nul.patch && -e $tmp/q/patches/sub/nul.patch ]]; then ok "NUL file moved to quarantine"; else not_ok "NUL file not quarantined"; fi
if grep -qF "patches/sub/nul.patch	contains NUL bytes" "$tmp/q/quarantined.tsv" 2>/dev/null; then ok "quarantine listed"; else not_ok "quarantine list: $(cat "$tmp/q/quarantined.tsv" 2>&1)"; fi
if [[ $out == *"moved patches/sub/nul.patch out of the artifact"* ]]; then ok "quarantine warned"; else not_ok "quarantine warning missing: $out"; fi
mkdir -p "$tmp/nq"
printf 'patch\0 secret' >"$tmp/nq/x.patch"
if "$script" "$tmp/nq" >/dev/null 2>&1; then not_ok "NUL file without --quarantine should fail"; else ok "NUL file without --quarantine fails"; fi

# Unset secrets: nothing to replace but patterns still apply; single files work.
printf 'plain text, nothing secret\n' >"$tmp/plain.txt"
cp "$tmp/plain.txt" "$tmp/plain.orig"
env -u ANTITHESIS_API_KEY -u ANTHROPIC_API_KEY -u GITHUB_TOKEN "$script" "$tmp/plain.txt" >/dev/null 2>&1
if cmp -s "$tmp/plain.txt" "$tmp/plain.orig"; then ok "unchanged file left alone"; else not_ok "plain file modified"; fi

if "$script" >/dev/null 2>&1; then not_ok "no args should fail"; else ok "usage error without args"; fi

[[ $fails -eq 0 ]]
