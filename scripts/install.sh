#!/usr/bin/env bash
# Install pinned snouty, Claude Code and the antithesis skill from the
# Antithesis plugin under $ATT_HOME. Paths and per-step environment come from
# scripts/env.sh; nothing is written to GITHUB_ENV or GITHUB_PATH.
set -euo pipefail

esc() { local s=$1; s=${s//'%'/'%25'}; s=${s//$'\r'/'%0D'}; s=${s//$'\n'/'%0A'}; printf '%s' "$s"; }
die() { echo "::error::$(esc "$*")"; exit 1; }

[ -n "${ATT_ACTION_PATH:-}" ] || die "ATT_ACTION_PATH is not set (action.yml passes it to this step)."
# shellcheck source=scripts/env.sh
. "$ATT_ACTION_PATH/scripts/env.sh"

# sha256 of the default versions' downloads, pinned here so a replaced release
# asset fails the install. Other versions fall back to the published checksums.
declare -A PINNED_SHA256=(
  [snouty-0.10.0-x86_64-unknown-linux-musl]=d9a2cfe404cbbd82a5658dffaed3fddffb80773498b4eaac7bedb0d22cf1b7bc
  [snouty-0.10.0-aarch64-unknown-linux-musl]=733eca41e258c20eedd24c207ee2e59dd88456e0e549f703554ef425b9682af1
  [claude-2.1.312-linux-x64]=4f4178ce41d83e23341ebfbaecdbcf8ea6bf7baea0690025abe49eeec3a5d01d
  [claude-2.1.312-linux-arm64]=dc4af28917455e009d26704b82a438353a06149e825b6cdf782908b2d28661f5
  [claude-2.1.312-linux-x64-musl]=78adef63924b762580b039c9ff0dd2ae44eb06171d467db62fd9040442505f76
  [claude-2.1.312-linux-arm64-musl]=62555d1d87e4fff49298b70f306ef851fa167fc58b179958680f7c4d407a8c5c
)

for v in ATT_SNOUTY_VERSION ATT_CLAUDE_CODE_VERSION ATT_PLUGIN_REF; do
  [ -n "${!v:-}" ] || die "$v is not set (action.yml passes it to this step)."
done

# A second use of the action in the same job must not see the first one's
# findings, commands.log or session id.
for d in "$ATT_OUT" "$ATT_WORK"; do
  case $d in ""|/) die "Refusing to wipe '$d'." ;; esac
done
rm -rf "$ATT_OUT" "$ATT_WORK"
mkdir -p "$ATT_HOME"/{bin,libexec,plugin,worktrees} "$CLAUDE_CONFIG_DIR" "$ATT_WORK" "$ATT_OUT"
: > "$ATT_COMMANDS_LOG"
: > "$SNOUTY_SETTINGS_PATH" # empty on purpose, see env.sh

for tool in jq curl tar xz sha256sum; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "$tool is required but was not found on PATH (GitHub-hosted Ubuntu runners include it; install it on self-hosted runners)."
done

[ "$(uname -s)" = Linux ] || die "This action runs on Linux runners only (this one is $(uname -s))."
case "$(uname -m)" in
  x86_64|amd64) snouty_target=x86_64-unknown-linux-musl; cc_platform=linux-x64 ;;
  aarch64|arm64) snouty_target=aarch64-unknown-linux-musl; cc_platform=linux-arm64 ;;
  *) die "Unsupported CPU architecture '$(uname -m)'; need x86_64 or aarch64." ;;
esac
if [ -e /lib/libc.musl-x86_64.so.1 ] || [ -e /lib/libc.musl-aarch64.so.1 ] ||
   { ldd --version 2>&1 || true; } | grep -qi musl; then
  cc_platform+=-musl
fi

dl=$(mktemp -d "$ATT_HOME/.download.XXXXXX")
trap 'rm -rf "$dl"' EXIT

fetch() { # url dest
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 30 \
    -o "$2" "$1" || die "Download failed: $1"
}
verify_sha256() { # file expected
  local got
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || die "Checksum mismatch for $(basename "$1"): expected $2, got $got."
}
not_pinned() { # what
  echo "::warning::$1 is not one of the versions pinned in install.sh, so its checksum comes from the same place as the download and is not independently pinned."
}

# --- snouty ----------------------------------------------------------------------
# The antithesis skill needs snouty 0.10.0 or later, and preflight.sh reads the
# `snouty doctor --json` report in the shape 0.10.0 prints.
snouty_min=0.10.0
snouty_ver=${ATT_SNOUTY_VERSION#v}
[[ $snouty_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  die "snouty-version '$ATT_SNOUTY_VERSION' is not a release version like $snouty_min."
[ "$(printf '%s\n' "$snouty_min" "$snouty_ver" | sort -V | sed -n 1p)" = "$snouty_min" ] ||
  die "snouty-version must be $snouty_min or newer (got $snouty_ver)."

echo "::group::Install snouty $snouty_ver ($snouty_target)"
asset="snouty-$snouty_target.tar.xz"
url="https://github.com/antithesishq/snouty/releases/download/v$snouty_ver/$asset"
want=${PINNED_SHA256[snouty-$snouty_ver-$snouty_target]:-}
if [ -z "$want" ]; then
  not_pinned "snouty $snouty_ver ($snouty_target)"
  fetch "$url.sha256" "$dl/$asset.sha256"
  read -r want _ < "$dl/$asset.sha256" || true
  want=${want,,}
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "Could not read a SHA-256 checksum from $url.sha256."
fi
fetch "$url" "$dl/$asset"
verify_sha256 "$dl/$asset" "$want"
tar -xJf "$dl/$asset" -C "$dl" "snouty-$snouty_target/snouty" ||
  die "$asset does not contain snouty-$snouty_target/snouty."
mv -f "$dl/snouty-$snouty_target/snouty" "$ATT_SNOUTY_REAL"
chmod 0755 "$ATT_SNOUTY_REAL"
snouty_reported=$("$ATT_SNOUTY_REAL" --version) || die "The installed snouty does not run."
[[ " $snouty_reported " == *" $snouty_ver "* ]] ||
  die "Expected snouty $snouty_ver, but the binary reports '$snouty_reported'."
echo "$snouty_reported (sha256 $want) -> $ATT_SNOUTY_REAL"

[ -f "$ATT_ACTION_PATH/shim/snouty" ] || die "Missing $ATT_ACTION_PATH/shim/snouty."
install -m 0755 "$ATT_ACTION_PATH/shim/snouty" "$ATT_HOME/bin/snouty"
echo "shim -> $ATT_HOME/bin/snouty"
echo "::endgroup::"

# --- Claude Code -----------------------------------------------------------------
# The native binary straight from the release bucket
# (https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing).
CC_RELEASES=https://downloads.claude.ai/claude-code-releases
cc_ver=$ATT_CLAUDE_CODE_VERSION
[[ $cc_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "claude-code-version must be an exact release like 2.1.312 (got '$cc_ver')."

echo "::group::Install Claude Code $cc_ver ($cc_platform)"
want=${PINNED_SHA256[claude-$cc_ver-$cc_platform]:-}
if [ -z "$want" ]; then
  not_pinned "Claude Code $cc_ver ($cc_platform)"
  fetch "$CC_RELEASES/$cc_ver/manifest.json" "$dl/manifest.json"
  [ "$(jq -r '.version' "$dl/manifest.json")" = "$cc_ver" ] ||
    die "The Claude Code manifest at $CC_RELEASES/$cc_ver is for another version."
  want=$(jq -r --arg p "$cc_platform" '.platforms[$p].checksum // empty' "$dl/manifest.json")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "Claude Code $cc_ver has no $cc_platform build."
fi
fetch "$CC_RELEASES/$cc_ver/$cc_platform/claude" "$dl/claude"
verify_sha256 "$dl/claude" "$want"
mv -f "$dl/claude" "$ATT_HOME/bin/claude"
chmod 0755 "$ATT_HOME/bin/claude"
cc_reported=$("$ATT_HOME/bin/claude" --version) || die "The installed Claude Code does not run."
[[ $cc_reported == "$cc_ver" || $cc_reported == "$cc_ver "* ]] ||
  die "Expected Claude Code $cc_ver, but the binary reports '$cc_reported'."
echo "$cc_reported (sha256 $want) -> $ATT_HOME/bin/claude"
echo "::endgroup::"

# --- the antithesis skill from the Antithesis plugin ---------------------------------
# Only the antithesis skill is installed, with a manifest that keeps the
# plugin's name and version: not the plugin's MCP config or anything else.
ref=$ATT_PLUGIN_REF
[[ $ref =~ ^[0-9a-f]{40}$ ]] ||
  die "plugin-ref must be a full 40-character commit SHA of antithesishq/antithesis-plugin (got '$ref')."
echo "::group::Install the antithesis skill (antithesishq/antithesis-plugin@$ref)"
fetch "https://codeload.github.com/antithesishq/antithesis-plugin/tar.gz/$ref" "$dl/plugin.tar.gz"
tar -tzf "$dl/plugin.tar.gz" > "$dl/plugin.list" || die "The antithesis-plugin download is not a tarball."
top=$(sed -n '1{s#/.*##;p;}' "$dl/plugin.list")
[ "$top" = "antithesis-plugin-$ref" ] ||
  die "Unexpected top-level directory '$top' in the antithesis-plugin tarball."
awk -v t="$top/" 'index($0, t) != 1 { bad = 1 } END { exit bad }' "$dl/plugin.list" ||
  die "The antithesis-plugin tarball has entries outside $top/."
src=$top/plugins/antithesis
for f in .claude-plugin/plugin.json skills/antithesis/SKILL.md; do
  grep -qxF "$src/$f" "$dl/plugin.list" ||
    die "antithesishq/antithesis-plugin@$ref has no plugins/antithesis/$f."
done
mkdir "$dl/plugin"
tar -xzf "$dl/plugin.tar.gz" -C "$dl/plugin" --no-same-owner \
  "$src/.claude-plugin/plugin.json" "$src/skills/antithesis"
# prompts/triage.md invokes the skill as /antithesis:antithesis.
plugin_name=$(jq -r '.name // empty' "$dl/plugin/$src/.claude-plugin/plugin.json" 2>/dev/null) ||
  die "plugins/antithesis/.claude-plugin/plugin.json at antithesishq/antithesis-plugin@$ref is not valid JSON."
[ "$plugin_name" = antithesis ] ||
  die "Expected the plugin at antithesishq/antithesis-plugin@$ref to be named 'antithesis' (got '$plugin_name')."
rm -rf "$ATT_HOME/plugin"
mkdir -p "$ATT_HOME/plugin/.claude-plugin" "$ATT_HOME/plugin/skills"
mv "$dl/plugin/$src/skills/antithesis" "$ATT_HOME/plugin/skills/antithesis"
jq --arg ref "$ref" '{
  name,
  version: (.version // "0.0.0"),
  description: ("The antithesis skill from antithesishq/antithesis-plugin@" + $ref
                + ", packaged by antithesis-triage-action.")
}' "$dl/plugin/$src/.claude-plugin/plugin.json" > "$ATT_HOME/plugin/.claude-plugin/plugin.json"
(cd "$ATT_HOME" && find plugin -type f | sort)
echo "::endgroup::"

# --- versions.json and session id --------------------------------------------------
# github.action_ref can be empty inside composite actions, so fall back to the
# ref in the action's checkout path (.../_actions/<owner>/<repo>/<ref>).
action_ref=${ATT_ACTION_REF:-${GITHUB_ACTION_REF:-}}
if [ -z "$action_ref" ]; then
  case $ATT_ACTION_PATH in
    */_actions/*/*/*) IFS=/ read -r _ _ action_ref _ <<<"${ATT_ACTION_PATH#*/_actions/}" ;;
    "${GITHUB_WORKSPACE:-//}"*) action_ref=local ;;
  esac
fi
jq -n --arg action_ref "${action_ref:-unknown}" --arg snouty "$snouty_ver" \
  --arg claude_code "$cc_ver" --arg plugin_ref "$ref" \
  '{action_ref: $action_ref, snouty: $snouty, claude_code: $claude_code, plugin_ref: $plugin_ref}' \
  > "$ATT_WORK/versions.json"

session_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)
session_id=${session_id,,}
[[ $session_id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  die "Could not generate a session UUID."
printf '%s\n' "$session_id" > "$ATT_WORK/session-id"

echo "Installed snouty $snouty_ver, Claude Code $cc_ver, antithesis-plugin@$ref (action ${action_ref:-unknown}); session $session_id."
