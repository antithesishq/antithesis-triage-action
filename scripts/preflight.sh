#!/usr/bin/env bash
# Stop before spending any model tokens if the credentials are missing or
# `snouty doctor` fails. Calls the real snouty directly: this is the action's
# own check, so it stays out of the agent's commands.log.
set -euo pipefail

esc() { local s=$1; s=${s//'%'/'%25'}; s=${s//$'\r'/'%0D'}; s=${s//$'\n'/'%0A'}; printf '%s' "$s"; }
die() { echo "::error::$(esc "$*")"; exit 1; }

[ -n "${ATT_ACTION_PATH:-}" ] || die "ATT_ACTION_PATH is not set (action.yml passes it to this step)."
# env.sh pins ANTITHESIS_BASE_URL and an empty SNOUTY_SETTINGS_PATH, so a
# .snouty.toml in the repo can't redirect the API key.
# shellcheck source=scripts/env.sh
. "$ATT_ACTION_PATH/scripts/env.sh"

[ -n "${ANTITHESIS_API_KEY:-}" ] ||
  die "ANTITHESIS_API_KEY is not set. Pass it to the action step from a secret: env: ANTITHESIS_API_KEY: \${{ secrets.ANTITHESIS_API_KEY }}"
[ -n "${ANTITHESIS_TENANT:-}" ] ||
  die "ANTITHESIS_TENANT is not set. Pass your tenant name to the action step: env: ANTITHESIS_TENANT: \${{ vars.ANTITHESIS_TENANT }}"

set_flag() { case "${1:-}" in ''|0|false|FALSE|False|no|off) return 1 ;; *) return 0 ;; esac; }
if [ -z "${ANTHROPIC_API_KEY:-}" ] &&
   ! set_flag "${CLAUDE_CODE_USE_BEDROCK:-}" &&
   ! set_flag "${CLAUDE_CODE_USE_VERTEX:-}" &&
   ! set_flag "${CLAUDE_CODE_USE_FOUNDRY:-}"; then
  msg="No model credential. Set ANTHROPIC_API_KEY from a secret, or set CLAUDE_CODE_USE_BEDROCK=1, CLAUDE_CODE_USE_VERTEX=1 or CLAUDE_CODE_USE_FOUNDRY=1 together with that provider's credentials."
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    msg+=" CLAUDE_CODE_OAUTH_TOKEN is set, but the agent runs Claude Code with --bare, which does not read OAuth credentials."
  fi
  die "$msg"
fi


snouty="${ATT_SNOUTY_REAL:-}"
if [ -z "$snouty" ] || [ ! -x "$snouty" ]; then
  die "snouty is not installed (ATT_SNOUTY_REAL='$snouty'). Did the install step fail?"
fi
command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH."
[ -f "$SNOUTY_SETTINGS_PATH" ] ||
  die "snouty's settings file $SNOUTY_SETTINGS_PATH is missing. Did the install step fail?"

# doctor exits 1 when a check fails but still prints its JSON report.
err=$(mktemp)
trap 'rm -f "$err"' EXIT
rc=0
report=$(timeout 120 "$snouty" doctor --json 2>"$err") || rc=$?

echo "::group::snouty doctor"
if ! jq -e 'type == "object" and (.ok | type == "boolean") and (.checks | type == "array")' \
     >/dev/null 2>&1 <<<"$report"; then
  cat "$err" >&2
  echo "::endgroup::"
  die "snouty doctor --json did not print a report (exit $rc): $(head -c 500 "$err")"
fi
jq -r '.checks[] | "\(.status)\t\(.name)\t\(.message)"' <<<"$report"
jq -r '"tenant: \(.settings.tenant // "not set")"' <<<"$report"
[ -s "$err" ] && cat "$err" >&2
echo "::endgroup::"

# Triage only talks to the API, so container runtime / Compose failures (which
# snouty launch needs) are downgraded to warnings.
not_needed='["container_runtime", "docker_compose"]'
api_key=$(jq -r 'first(.checks[] | select(.name == "api_key") | .status) // "absent"' <<<"$report")
blocking=$(jq -r --argjson skip "$not_needed" \
  '[.checks[] | select(.status == "error" and (.name as $n | $skip | index($n) | not))] | length' <<<"$report")
if [ "$api_key" = ok ] && [ "$blocking" = 0 ]; then
  skipped=$(jq -r --argjson skip "$not_needed" \
    '[.checks[] | select(.status == "error" and (.name as $n | $skip | index($n))) | .name] | join(", ")' <<<"$report")
  [ -n "$skipped" ] && echo "::warning::snouty doctor: ignoring failed checks not needed for triage: $skipped"
  echo "snouty doctor: checks needed for triage passed."
  exit 0
fi

failing=$(jq -r '[.checks[] | select(.status == "error")
  | "\(.name): \(.message)" + ([.notes[]?.text] | if length > 0 then " (" + join("; ") + ")" else "" end)]
  | join(" | ")' <<<"$report")

msg="snouty doctor failed, so the triage agent was not started."
[ -n "$failing" ] && msg+=" Failing checks: $failing."
if [ "$api_key" != ok ]; then
  msg+=" The api_key check is '$api_key': set ANTITHESIS_API_KEY to a valid Antithesis API key."
fi
die "$msg"
