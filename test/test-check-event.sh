#!/usr/bin/env bash
# Tests for scripts/check-event.sh.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/scripts/check-event.sh"
fails=0

check() { # expected_rc event [var] (empty event = unset; var defaults to ATT_EVENT_NAME)
  local want=$1 event=$2 var=${3:-ATT_EVENT_NAME} rc=0 out
  if [ -n "$event" ]; then
    out=$(env -u ATT_EVENT_NAME -u GITHUB_EVENT_NAME "$var=$event" "$script" 2>&1) || rc=$?
  else
    out=$(env -u ATT_EVENT_NAME -u GITHUB_EVENT_NAME "$script" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne "$want" ]; then
    echo "not ok - '${event:-unset}': exit $rc, want $want"; fails=$((fails + 1)); return
  fi
  if [ "$want" -ne 0 ] && { [[ $out != "::error::"* ]] || [[ $out != *"fork PRs get no secrets"* ]] ||
                            [[ $out != *"inject instructions"* ]]; }; then
    echo "not ok - '${event:-unset}': error message missing or incomplete: $out"; fails=$((fails + 1)); return
  fi
  echo "ok - '${event:-unset}' -> exit $rc"
}

check 0 schedule
check 0 workflow_dispatch
for e in pull_request pull_request_target pull_request_review pull_request_review_comment \
         issue_comment issues discussion_comment push workflow_run repository_dispatch ""; do
  check 1 "$e"
done

# Falls back to GITHUB_EVENT_NAME; ATT_EVENT_NAME wins when both are set.
check 0 schedule GITHUB_EVENT_NAME
check 1 pull_request GITHUB_EVENT_NAME
rc=0; ATT_EVENT_NAME=pull_request GITHUB_EVENT_NAME=schedule "$script" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then echo "ok - ATT_EVENT_NAME wins over GITHUB_EVENT_NAME"
else echo "not ok - ATT_EVENT_NAME wins over GITHUB_EVENT_NAME (exit $rc)"; fails=$((fails + 1)); fi

[ "$fails" -eq 0 ]
