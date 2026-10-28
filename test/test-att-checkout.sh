#!/usr/bin/env bash
# Tests for scripts/att-checkout against a local "origin" repository.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/att-checkout"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

ok() { if [ "$1" -eq 0 ]; then echo "ok - $2"; else echo "not ok - $2"; failures=$((failures + 1)); fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git_q() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# origin with two commits; the clone (the "checkout") only has the first.
git_q init "$tmp/origin"
echo one > "$tmp/origin/f"; git_q -C "$tmp/origin" add f; git_q -C "$tmp/origin" commit -m one
first=$(git -C "$tmp/origin" rev-parse HEAD)
git_q clone "$tmp/origin" "$tmp/ws"
echo two > "$tmp/origin/f"; git_q -C "$tmp/origin" commit -am two
second=$(git -C "$tmp/origin" rev-parse HEAD)
git_q -C "$tmp/origin" config uploadpack.allowAnySHA1InWant true
git_q -C "$tmp/origin" tag v2

# checkout <args...>: run att-checkout as the agent would; sets rc and out.
checkout() {
  rc=0
  out=$(env -i PATH="$PATH" HOME="$tmp" ATT_HOME="$tmp/home" GITHUB_WORKSPACE="$tmp/ws" bash "$script" "$@" 2>&1) || rc=$?
}
wt="$tmp/home/worktrees"

checkout; [ "$rc" -eq 2 ]; ok $? "no arguments is a usage error"
checkout "${first:0:12}"; [ "$rc" -eq 2 ] && [[ "$out" == *"git rev-parse"* ]]; ok $? "short SHA is refused with a hint"
checkout "$(tr 'a-f' 'A-F' <<< "$first")"; [ "$rc" -eq 2 ]; ok $? "uppercase SHA is refused"
checkout "--upload-pack=touch $tmp/pwned"; [ "$rc" -eq 2 ] && [ ! -e "$tmp/pwned" ]; ok $? "option-looking argument is refused"
checkout "$first" ../../evil; [ "$rc" -eq 2 ]; ok $? "path-like name is refused"
checkout "$first" patch-Bad; [ "$rc" -eq 2 ]; ok $? "name with uppercase is refused"
checkout "$first" patch-x extra; [ "$rc" -eq 2 ]; ok $? "extra argument is refused"
[ ! -e "$wt" ] || [ -z "$(ls -A "$wt")" ]; ok $? "refused calls create no worktree"

checkout "$first"
[ "$rc" -eq 0 ] && [ "$(git -C "$wt/${first:0:12}" rev-parse HEAD)" = "$first" ]; ok $? "checks out a local commit at worktrees/<sha12>"
checkout "$first"; [ "$rc" -eq 0 ] && [[ "$out" == *"already checked out"* ]]; ok $? "running again is a no-op"

checkout "$second" patch-fix-1
[ "$rc" -eq 0 ] && [ "$(git -C "$wt/patch-fix-1" rev-parse HEAD)" = "$second" ]; ok $? "fetches a missing commit from origin into worktrees/patch-<name>"
[ -z "$(git -C "$tmp/ws" for-each-ref refs/tags)" ]; ok $? "fetch brings no tags"
checkout "$first" patch-fix-1; [ "$rc" -eq 1 ] && [[ "$out" == *"another commit"* ]]; ok $? "existing target at another commit is refused"

checkout 0123456789012345678901234567890123456789; [ "$rc" -eq 1 ]; ok $? "unknown commit fails"
[ ! -e "$wt/012345678901" ]; ok $? "unknown commit leaves no worktree"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
