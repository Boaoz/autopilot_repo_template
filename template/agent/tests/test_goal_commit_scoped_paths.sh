#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_GOAL="$REPO_ROOT/agent/scripts/run-agent-goal.sh"
LIB="$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

remote="$tmpdir/remote.git"
work="$tmpdir/work"
git init --bare -q "$remote"
git clone -q "$remote" "$work"
cd "$work"
git config user.name "test"
git config user.email "test@example.invalid"

printf 'base\n' > README.md
printf 'machine/\n' > .gitignore
git add README.md .gitignore
git commit -q -m base
git push -q -u origin HEAD:test-branch
git switch -q -c test-branch

mkdir -p src/issue-9 res/issue-9 machine/runs/issue-9
printf 'code\n' > src/issue-9/a.py
printf 'result\n' > res/issue-9/out.txt
printf 'updated repo status\n' > README.md
printf 'clickhouse-connect==0.8.0\n' > requirements.txt
printf 'local log\n' > machine/runs/issue-9/latest.log
printf 'unrelated\n' > unrelated.txt

sed -n '/^commit_and_push()/,/^}$/p' "$RUN_GOAL" > "$tmpdir/commit_and_push.sh"
# shellcheck source=/dev/null
source "$LIB"
# shellcheck source=/dev/null
source "$tmpdir/commit_and_push.sh"

agent-git() { git "$@"; }
log() { printf '%s\n' "$1" >> "$tmpdir/log-events"; }
SRC_DIR="src/issue-9"
RESULTS_DIR="res/issue-9"

commit_and_push test-branch "agent: implement issue #9" false

committed="$(git diff-tree --no-commit-id --name-only -r HEAD | sort)"
expected="$(printf '%s\n' README.md requirements.txt res/issue-9/out.txt src/issue-9/a.py)"
[[ "$committed" == "$expected" ]]

git status --porcelain --untracked-files=all | grep -Fq '?? unrelated.txt'
git status --porcelain --ignored | grep -Fq '!! machine/'

echo "goal commit scoped-path checks OK"
