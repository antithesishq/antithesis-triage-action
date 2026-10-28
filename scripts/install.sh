#!/usr/bin/env bash
# Install pinned snouty, Claude Code and the antithesis-triage skill, and export
# the shared environment for the later steps (plans/contract.md).
set -euo pipefail

esc() { local s=$1; s=${s//'%'/'%25'}; s=${s//$'\r'/'%0D'}; s=${s//$'\n'/'%0A'}; printf '%s' "$s"; }
die() { echo "::error::$(esc "$*")"; exit 1; }

need_vars() {
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is not set (action.yml passes it to this step)."
  done
}
need_vars ATT_ACTION_PATH ATT_HOME

ATT_OUT="${ATT_OUT:-$ATT_HOME/out}"
ATT_WORK="$ATT_HOME/work"
CLAUDE_CONFIG_DIR="$ATT_HOME/claude-config"
ATT_SNOUTY_REAL="$ATT_HOME/libexec/snouty"
ATT_COMMANDS_LOG="$ATT_OUT/commands.log"
export ATT_OUT ATT_WORK CLAUDE_CONFIG_DIR ATT_SNOUTY_REAL ATT_COMMANDS_LOG

# --- Environment first, so `if: always()` steps get it even if install fails. --
env_vars=(ATT_ACTION_PATH ATT_HOME ATT_OUT ATT_WORK CLAUDE_CONFIG_DIR ATT_SNOUTY_REAL ATT_COMMANDS_LOG)
for v in "${env_vars[@]}"; do
  case ${!v} in *$'\n'*|*$'\r'*) die "$v contains a line break." ;; esac
done
{
  for v in "${env_vars[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done
  # Keep the pinned Claude Code version: no background self-update.
  echo "DISABLE_AUTOUPDATER=1"
} >> "${GITHUB_ENV:-/dev/null}"
echo "$ATT_HOME/bin" >> "${GITHUB_PATH:-/dev/null}"

mkdir -p "$ATT_HOME"/{bin,libexec,plugin,claude-config,worktrees} "$ATT_WORK" "$ATT_OUT"
: >> "$ATT_COMMANDS_LOG"
need_vars ATT_SNOUTY_VERSION ATT_CLAUDE_CODE_VERSION ATT_SKILLS_REF

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

# --- snouty ----------------------------------------------------------------------
snouty_ver=${ATT_SNOUTY_VERSION#v}
[[ $snouty_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  die "snouty-version '$ATT_SNOUTY_VERSION' is not a release version like 0.8.0."
[ "$(printf '%s\n' 0.8.0 "$snouty_ver" | sort -V | sed -n 1p)" = 0.8.0 ] ||
  die "snouty-version must be 0.8.0 or newer (got $snouty_ver)."

echo "::group::Install snouty $snouty_ver ($snouty_target)"
asset="snouty-$snouty_target.tar.xz"
url="https://github.com/antithesishq/snouty/releases/download/v$snouty_ver/$asset"
fetch "$url" "$dl/$asset"
fetch "$url.sha256" "$dl/$asset.sha256"
want=""
read -r want _ < "$dl/$asset.sha256" || true
want=${want,,}
[[ $want =~ ^[0-9a-f]{64}$ ]] || die "Could not read a SHA-256 checksum from $url.sha256."
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
# Native binary straight from the release bucket, checked against the release
# manifest, whose detached signature is checked against Anthropic's pinned
# release key (https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing).
CC_RELEASES=https://downloads.claude.ai/claude-code-releases
CC_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
CC_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

verify_manifest_signature() { # manifest sig_url
  if ! command -v gpg >/dev/null 2>&1; then
    echo "::warning::gpg not found; the Claude Code manifest signature was not checked (the binary checksum still is)."
    return 0
  fi
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dl/manifest.json.sig" "$2"; then
    echo "::warning::No manifest signature at $2 (published from 2.1.89 on); relying on the checksum only."
    return 0
  fi
  fetch "$CC_KEY_URL" "$dl/claude-code.asc"
  local gnupg status fprs
  gnupg=$(mktemp -d)
  gpg --homedir "$gnupg" --batch --quiet --import "$dl/claude-code.asc" >/dev/null 2>&1 ||
    die "Could not import the Claude Code release key from $CC_KEY_URL."
  status=$(gpg --homedir "$gnupg" --batch --status-fd 1 --verify "$dl/manifest.json.sig" "$1" 2>/dev/null) ||
    die "The Claude Code $cc_ver manifest signature does not verify."
  gpgconf --homedir "$gnupg" --kill all >/dev/null 2>&1 || true
  rm -rf "$gnupg"
  fprs=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }' <<<"$status")
  [[ $'\n'$fprs$'\n' == *$'\n'$CC_KEY_FPR$'\n'* ]] ||
    die "The Claude Code manifest is not signed by the pinned release key $CC_KEY_FPR."
  echo "manifest signature: good ($CC_KEY_FPR)"
}

cc_ver=$ATT_CLAUDE_CODE_VERSION
[[ $cc_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "claude-code-version must be an exact release like 2.1.312 (got '$cc_ver')."

echo "::group::Install Claude Code $cc_ver ($cc_platform)"
fetch "$CC_RELEASES/$cc_ver/manifest.json" "$dl/manifest.json"
verify_manifest_signature "$dl/manifest.json" "$CC_RELEASES/$cc_ver/manifest.json.sig"
[ "$(jq -r '.version' "$dl/manifest.json")" = "$cc_ver" ] ||
  die "The Claude Code manifest at $CC_RELEASES/$cc_ver is for another version."
want=$(jq -r --arg p "$cc_platform" '.platforms[$p].checksum // empty' "$dl/manifest.json")
[[ $want =~ ^[0-9a-f]{64}$ ]] || die "Claude Code $cc_ver has no $cc_platform build."
fetch "$CC_RELEASES/$cc_ver/$cc_platform/claude" "$dl/claude"
verify_sha256 "$dl/claude" "$want"
mv -f "$dl/claude" "$ATT_HOME/bin/claude"
chmod 0755 "$ATT_HOME/bin/claude"
cc_reported=$("$ATT_HOME/bin/claude" --version) || die "The installed Claude Code does not run."
[[ $cc_reported == "$cc_ver" || $cc_reported == "$cc_ver "* ]] ||
  die "Expected Claude Code $cc_ver, but the binary reports '$cc_reported'."
echo "$cc_reported (sha256 $want) -> $ATT_HOME/bin/claude"
echo "::endgroup::"

# --- antithesis-triage skill as a single-skill plugin ------------------------------
ref=$ATT_SKILLS_REF
[[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || die "skills-ref '$ref' is not a valid git ref."
echo "::group::Install the antithesis-triage skill (antithesishq/antithesis-skills@$ref)"
[[ $ref =~ ^[0-9a-f]{40}$ ]] ||
  echo "::warning::skills-ref '$ref' is not a full commit SHA, so the skill version is not pinned."
fetch "https://codeload.github.com/antithesishq/antithesis-skills/tar.gz/$ref" "$dl/skills.tar.gz"
tar -tzf "$dl/skills.tar.gz" > "$dl/skills.list" || die "The antithesis-skills download is not a tarball."
top=$(sed -n '1{s#/.*##;p;}' "$dl/skills.list")
[[ $top == antithesis-skills-* ]] ||
  die "Unexpected top-level directory '$top' in the antithesis-skills tarball."
awk -v t="$top/" 'index($0, t) != 1 { bad = 1 } END { exit bad }' "$dl/skills.list" ||
  die "The antithesis-skills tarball has entries outside $top/."
grep -qxF "$top/antithesis-triage/SKILL.md" "$dl/skills.list" ||
  die "antithesishq/antithesis-skills@$ref has no antithesis-triage/SKILL.md."
mkdir "$dl/skills"
tar -xzf "$dl/skills.tar.gz" -C "$dl/skills" --no-same-owner "$top/antithesis-triage"
rm -rf "$ATT_HOME/plugin"
mkdir -p "$ATT_HOME/plugin/.claude-plugin" "$ATT_HOME/plugin/skills"
mv "$dl/skills/$top/antithesis-triage" "$ATT_HOME/plugin/skills/antithesis-triage"
jq -n --arg ref "$ref" '{
  name: "antithesis-skills",
  version: "0.1.0-triage-only",
  description: ("Only the antithesis-triage skill, from antithesishq/antithesis-skills@" + $ref
                + ", packaged by antithesis-triage-action.")
}' > "$ATT_HOME/plugin/.claude-plugin/plugin.json"
(cd "$ATT_HOME" && find plugin -type f | sort)
echo "::endgroup::"

# --- versions.json and session id --------------------------------------------------
# GITHUB_ACTION_REF is often empty inside composite actions, so fall back to the
# ref in the action's checkout path (.../_actions/<owner>/<repo>/<ref>).
action_ref=${ATT_ACTION_REF:-${GITHUB_ACTION_REF:-}}
if [ -z "$action_ref" ]; then
  case $ATT_ACTION_PATH in
    */_actions/*/*/*) IFS=/ read -r _ _ action_ref _ <<<"${ATT_ACTION_PATH#*/_actions/}" ;;
    "${GITHUB_WORKSPACE:-//}"*) action_ref=local ;;
  esac
fi
jq -n --arg action_ref "${action_ref:-unknown}" --arg snouty "$snouty_ver" \
  --arg claude_code "$cc_ver" --arg skills_ref "$ref" \
  '{action_ref: $action_ref, snouty: $snouty, claude_code: $claude_code, skills_ref: $skills_ref}' \
  > "$ATT_WORK/versions.json"

session_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || true)
session_id=${session_id,,}
[[ $session_id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  die "Could not generate a session UUID."
printf '%s\n' "$session_id" > "$ATT_WORK/session-id"

echo "Installed snouty $snouty_ver, Claude Code $cc_ver, antithesis-triage@$ref (action ${action_ref:-unknown}); session $session_id."
