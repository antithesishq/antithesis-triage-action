#!/usr/bin/env bash
# Refuse every trigger except `schedule` and `workflow_dispatch`.
set -euo pipefail

# action.yml passes github.event_name as ATT_EVENT_NAME.
event="${ATT_EVENT_NAME:-${GITHUB_EVENT_NAME:-}}"
case "$event" in
  schedule|workflow_dispatch)
    echo "Triggered by '$event': OK."
    ;;
  *)
    echo "::error::antithesis-triage-action runs only on 'schedule' and 'workflow_dispatch' events, not '${event:-unset}'. Pull request events are refused because fork PRs get no secrets, and handing secrets to a PR-triggered run would expose your Antithesis and model API keys to an agent reading untrusted code. Comment and issue triggers are refused because anyone who can comment could start a paid agent session and inject instructions into its prompt. Use 'on: schedule' and/or 'on: workflow_dispatch'."
    exit 1
    ;;
esac
