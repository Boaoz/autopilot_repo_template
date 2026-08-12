#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/agent-inspect.yml"
SCRIPT="$REPO_ROOT/agent/scripts/agent-inspect.sh"
FIX_WORKFLOW="$REPO_ROOT/.github/workflows/agent-fix.yml"
ISSUE_TEMPLATE="$REPO_ROOT/.github/ISSUE_TEMPLATE/agent_inspect.yml"

[[ -f "$WORKFLOW" ]] || {
  echo "agent-inspect workflow is missing" >&2
  exit 1
}
[[ -x "$SCRIPT" ]] || {
  echo "agent-inspect script is missing or not executable" >&2
  exit 1
}

grep -Fq "startsWith(github.event.comment.body, '/agent inspect')" "$WORKFLOW"
grep -Fq "issues:" "$WORKFLOW"
grep -Fq "types: [opened]" "$WORKFLOW"
if grep -Fq "types: [opened, labeled]" "$WORKFLOW"; then
  echo "agent-inspect issue creation must not launch once for opened and again for labeled" >&2
  exit 1
fi
grep -Fq "contains(github.event.issue.labels.*.name, 'agent-inspect')" "$WORKFLOW"
grep -Fq "!startsWith(github.event.comment.body, '/agent cancel')" "$WORKFLOW"
grep -Fq "startsWith(github.event.comment.body, '/agent retry')" "$WORKFLOW"
grep -Fq "pull_request_review_comment:" "$WORKFLOW"
grep -Fq "./agent/scripts/agent-inspect.sh" "$WORKFLOW"
grep -Fq "runs-on: [self-hosted, Linux, agent-inspect]" "$WORKFLOW"
grep -Fq "contents: read" "$WORKFLOW"
grep -Fq "issues: write" "$WORKFLOW"
grep -Fq "pull-requests: read" "$WORKFLOW"

if grep -Fq "/agent inspect" "$FIX_WORKFLOW"; then
  echo "/agent inspect should not route through agent-fix" >&2
  exit 1
fi

grep -Fq "strip_inspect_question" "$SCRIPT"
grep -Fq "retry_readonly_git" "$SCRIPT"
grep -Fq "git worktree add" "$SCRIPT"
grep -Fq "agent-gh issue comment" "$SCRIPT"
grep -Fq "Treat the checkout and all pull requests as read-only" "$SCRIPT"
grep -Fq 'agent-opencode-exec.sh" --cd "$worktree"' "$SCRIPT"
grep -Fq 'INSPECT_ISSUE_MODE' "$SCRIPT"
grep -Fq 'Complete conversation in chronological order' "$SCRIPT"
grep -Fq 'read_inspect_conversation' "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
grep -Fq 'CONVERSATION="$(read_inspect_conversation "$COMMENT_TARGET")"' "$SCRIPT"
grep -Fq 'Issue or pull request opened by' "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
grep -Fq 'agent-gh issue view "$target"' "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
grep -Fq 'fetching main' "$SCRIPT"
grep -Fq 'agent_gh_issue_edit "$COMMENT_TARGET" --repo "$REPO" --add-label "agent-failed"' "$SCRIPT"
grep -Fq 'clear_agent_failed "$COMMENT_TARGET" "$REPO"' "$SCRIPT"

grep -Fq "labels:" "$ISSUE_TEMPLATE"
grep -Fq "agent-inspect" "$ISSUE_TEMPLATE"
grep -Fq "Every later human comment" "$ISSUE_TEMPLATE"

if grep -Fq "opencode run" "$SCRIPT"; then
  echo "agent-inspect should use the shared project-config OpenCode wrapper" >&2
  exit 1
fi

if grep -Eq "agent-git[[:space:]]+(push|commit)|agent-gh[[:space:]]+pr[[:space:]]+(edit|merge|close)|agent-gh[[:space:]]+issue[[:space:]]+edit" "$SCRIPT"; then
  echo "agent-inspect must not push commits or mutate PR/issue state beyond posting the answer comment" >&2
  exit 1
fi

echo "agent-inspect checks OK"
