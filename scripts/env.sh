# shellcheck shell=bash
# Sourced by every step script. Derives the action's paths from RUNNER_TEMP and
# configures snouty / Claude Code for the current step only. Nothing is written
# to GITHUB_ENV or GITHUB_PATH, so the caller's later steps are unaffected.
# Values already set in the environment win (tests rely on this).

ATT_HOME="${ATT_HOME:-${RUNNER_TEMP:?RUNNER_TEMP is not set}/antithesis-triage}"
ATT_OUT="${ATT_OUT:-$ATT_HOME/out}"           # uploaded as the artifact
ATT_WORK="${ATT_WORK:-$ATT_HOME/work}"        # scratch, never uploaded
ATT_SNOUTY_REAL="${ATT_SNOUTY_REAL:-$ATT_HOME/libexec/snouty}"
# Outside ATT_OUT so the agent can't edit it; finalize copies it into the artifact.
ATT_COMMANDS_LOG="${ATT_COMMANDS_LOG:-$ATT_WORK/commands.log}"
export ATT_HOME ATT_OUT ATT_WORK ATT_SNOUTY_REAL ATT_COMMANDS_LOG

export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$ATT_HOME/claude-config}"
export DISABLE_AUTOUPDATER=1

# snouty also reads ./.snouty.toml from the working directory (the customer's
# repo), whose base_url could send the API key elsewhere. Environment variables
# override settings files, so pin the API host and use an empty settings file
# (install.sh creates it).
export SNOUTY_SETTINGS_PATH="$ATT_HOME/snouty-settings.toml"
if [ -z "${ANTITHESIS_BASE_URL:-}" ] && [ -n "${ANTITHESIS_TENANT:-}" ]; then
  export ANTITHESIS_BASE_URL="https://${ANTITHESIS_TENANT}.antithesis.com"
fi

# The shim (bin/snouty) and claude live in bin/; the real snouty stays off PATH.
case ":$PATH:" in
  *":$ATT_HOME/bin:"*) ;;
  *) export PATH="$ATT_HOME/bin:$PATH" ;;
esac
