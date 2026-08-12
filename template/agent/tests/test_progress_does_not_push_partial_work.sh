#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

# shellcheck source=/dev/null
source "$LIB"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
export AGENT_MACHINE_DIR="$tmpdir/machine"

remote="$tmpdir/remote.git"
work="$tmpdir/work"
git init -q --bare "$remote"
git clone -q "$remote" "$work"
git -C "$work" config user.name test
git -C "$work" config user.email test@example.invalid

cd "$work"
printf 'base\n' > README.md
git add README.md
git commit -q -m base
git push -q origin HEAD:main
git switch -q -c agent/issue-12-long-run
git push -q -u origin agent/issue-12-long-run

mkdir -p src/issue-12 res/issue-12
printf 'partial code\n' > src/issue-12/a.py
printf 'partial result\n' > res/issue-12/out.txt
printf 'ignore me\n' > unrelated.txt

before_head="$(git rev-parse HEAD)"
sync_intermediate_agent_artifacts 12 implement agent/issue-12-long-run goal

after_head="$(git rev-parse HEAD)"
remote_head="$(git ls-remote origin refs/heads/agent/issue-12-long-run | awk '{print $1}')"

[[ "$after_head" == "$before_head" ]]
[[ "$remote_head" == "$before_head" ]]
git status --porcelain --untracked-files=all | grep -Fq '?? src/issue-12/a.py'
git status --porcelain --untracked-files=all | grep -Fq '?? res/issue-12/out.txt'
git status --porcelain --untracked-files=all | grep -Fq '?? unrelated.txt'

checkpoint="$AGENT_MACHINE_DIR/runs/issue-12/checkpoint"
[[ -f "$checkpoint/src/issue-12/a.py" ]]
[[ -f "$checkpoint/res/issue-12/out.txt" ]]
[[ -f "$checkpoint/metadata.env" ]]
[[ ! -e "$checkpoint/unrelated.txt" ]]
grep -Fq 'phase=implement' "$checkpoint/metadata.env"
grep -Fq 'branch=agent/issue-12-long-run' "$checkpoint/metadata.env"
grep -Fq 'kind=goal' "$checkpoint/metadata.env"

echo "progress does not push partial work checks OK"
