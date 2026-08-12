#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
PREPARE="$REPO_ROOT/agent/scripts/agent-prepare-workspace.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export AGENT_MACHINE_DIR="$tmpdir/machine"
export GITHUB_REPOSITORY="Boaoz/regulations-test3"

remote="$tmpdir/remote.git"
work="$tmpdir/work"
git init -q --bare "$remote"
git clone -q "$remote" "$work"
git -C "$work" config user.name test
git -C "$work" config user.email test@example.invalid

cd "$work"
printf 'base\n' > README.md
mkdir -p agent/scripts/bin
cat > agent/scripts/bin/agent-git <<'SH'
#!/usr/bin/env bash
exec git "$@"
SH
cat > agent/scripts/bin/agent-gh <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"issue view 12"* ]]; then
  printf 'Long resumable job\n'
  exit 0
fi
exit 1
SH
chmod +x agent/scripts/bin/agent-git agent/scripts/bin/agent-gh
git add README.md agent/scripts/bin/agent-git agent/scripts/bin/agent-gh
git commit -q -m base
git push -q origin HEAD:main
git switch -q -c agent/issue-12-long-resumable-job
git push -q -u origin agent/issue-12-long-resumable-job

mkdir -p "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint/src/issue-12"
mkdir -p "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint/res/issue-12"
printf 'checkpoint code\n' > "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint/src/issue-12/a.py"
printf 'checkpoint result\n' > "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint/res/issue-12/out.txt"
cat > "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint/metadata.env" <<'EOF'
issue=12
phase=implement
branch=agent/issue-12-long-resumable-job
kind=goal
created=2026-07-13T00:00:00Z
EOF

# shellcheck source=/dev/null
source "$LIB"
restore_agent_checkpoint 12 implement agent/issue-12-long-resumable-job goal
[[ "$(cat src/issue-12/a.py)" == "checkpoint code" ]]
[[ "$(cat res/issue-12/out.txt)" == "checkpoint result" ]]

printf 'remote branch code\n' > src/issue-12/a.py
printf 'remote branch result\n' > res/issue-12/out.txt
restore_agent_checkpoint 12 fix agent/issue-12-long-resumable-job goal
[[ "$(cat src/issue-12/a.py)" == "remote branch code" ]]
[[ "$(cat res/issue-12/out.txt)" == "remote branch result" ]]

restore_agent_checkpoint 12 implement agent/issue-12-different-branch goal
[[ "$(cat src/issue-12/a.py)" == "remote branch code" ]]
[[ "$(cat res/issue-12/out.txt)" == "remote branch result" ]]

grep -Fq 'restore_agent_checkpoint "$ISSUE" "$PHASE" "$branch" "$MODE"' "$PREPARE"
grep -Fq 'clear_agent_checkpoint "$ISSUE"' "$PREPARE"

clear_agent_checkpoint 12
[[ ! -e "$AGENT_MACHINE_DIR/runs/issue-12/checkpoint" ]]

echo "checkpoint restore checks OK"
