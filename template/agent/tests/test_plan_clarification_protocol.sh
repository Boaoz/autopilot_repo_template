#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cp -a "$REPO_ROOT" "$tmpdir/repo"
repo="$tmpdir/repo"
rm -rf "$repo/.git"
mkdir -p "$repo/machine/runs/issue-41"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.test
git -C "$repo" add .
git -C "$repo" commit -qm 'test: initial fixture'
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" fetch origin main:refs/remotes/origin/main
git clone -q "$repo" "$tmpdir/workspace"
workspace="$tmpdir/workspace"

cat > "$workspace/agent/scripts/bin/agent-gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'.title'*) printf '%s\n' 'Clarification protocol test' ;;
  *'.body'*) printf '%s\n' 'Test question-file planning pauses.' ;;
  *'.url'*) printf '%s\n' 'https://example.test/issues/41' ;;
  *'issue comment'*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$workspace/agent/scripts/bin/agent-gh"

cat > "$workspace/agent/scripts/agent-opencode-exec.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
question_file="$(printf '%s\n' "$1" | awk '/exact local file ONLY:/{getline; print; exit}')"
printf '%s\n' \
  'Which file format should the loader support?' \
  'Should malformed input raise an error or be skipped?' > "$question_file"
EOF
chmod +x "$workspace/agent/scripts/agent-opencode-exec.sh"

set +e
GITHUB_REPOSITORY=example/test GITHUB_WORKSPACE="$workspace" AGENT_PROJECT_ROOT="$repo" \
  "$workspace/agent/scripts/run-agent-goal.sh" plan 41 >"$tmpdir/out" 2>"$tmpdir/err"
status=$?
set -e

[[ "$status" -eq 20 ]]
log_file="$(cat "$repo/machine/runs/issue-41/latest.log")"
[[ ! -e "$repo/machine/runs/issue-41/plan.md" ]]
grep -Fq 'Planning clarification needed:' "$log_file"
grep -Fq 'Which file format should the loader support?' "$log_file"
grep -Fq 'Should malformed input raise an error or be skipped?' "$log_file"

cat > "$workspace/agent/scripts/agent-opencode-exec.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
plan_file="$(printf '%s\n' "$1" | awk '/exact local file path ONLY:/{getline; print; exit}')"
mkdir -p "$(dirname "$plan_file")"
cat > "$plan_file" <<'PLAN'
<!-- agent-src-target
src/issue-42/
-->

<!-- agent-results-target
res/issue-42/
-->

<!-- agent-verify
./agent/scripts/verify.sh
-->
PLAN
EOF
chmod +x "$workspace/agent/scripts/agent-opencode-exec.sh"

set +e
GITHUB_REPOSITORY=example/test GITHUB_WORKSPACE="$workspace" AGENT_PROJECT_ROOT="$repo" \
  "$workspace/agent/scripts/run-agent-goal.sh" plan 42 >"$tmpdir/plan-out" 2>"$tmpdir/plan-err"
plan_status=$?
set -e

[[ "$plan_status" -eq 0 ]]
[[ -s "$workspace/machine/runs/issue-42/plan.md" ]]
[[ -s "$repo/machine/runs/issue-42/plan.md" ]]
cmp "$workspace/machine/runs/issue-42/plan.md" "$repo/machine/runs/issue-42/plan.md"

echo "plan clarification protocol checks OK"
