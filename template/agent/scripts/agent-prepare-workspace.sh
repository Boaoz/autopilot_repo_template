#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

ISSUE="${1:-}"
PHASE="${2:-plan}"
MODE="${3:-goal}"
BRANCH_OVERRIDE="${4:-}"

if [[ -z "$ISSUE" ]]; then
  echo "Usage: $0 <issue-number> [phase] [goal|knowledge] [branch]" >&2
  exit 1
fi

cd "$REPO_ROOT"
agent-git fetch origin --prune

if [[ -n "$BRANCH_OVERRIDE" ]]; then
  branch="$BRANCH_OVERRIDE"
elif [[ "$MODE" == "knowledge" ]]; then
  issue_title="$(agent-gh issue view "$ISSUE" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}" --json title --jq .title 2>/dev/null || echo "issue-${ISSUE}")"
  branch_slug="$(echo "$issue_title" | sed 's/^\[agent-knowledge\][[:space:]]*//I' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)"
  branch="agent/knowledge-issue-${ISSUE}-${branch_slug}"
else
  issue_title="$(agent-gh issue view "$ISSUE" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}" --json title --jq .title 2>/dev/null || echo "issue-${ISSUE}")"
  branch_slug="$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)"
  branch="agent/issue-${ISSUE}-${branch_slug}"
fi

sync_main_into_branch() {
  local branch="$1"

  if agent-git merge-base --is-ancestor origin/main HEAD; then
    return 0
  fi

  echo "Syncing origin/main into ${branch} for latest agent tooling..."
  if ! agent-git merge origin/main --no-edit -m "agent: sync main into ${branch}"; then
    echo "Failed to sync origin/main into ${branch}. Resolve the branch conflict before rerunning the agent phase." >&2
    agent-git merge --abort 2>/dev/null || true
    exit 1
  fi
}

if agent-git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
  agent-git checkout -B "$branch" "origin/$branch"
  sync_main_into_branch "$branch"
else
  agent-git checkout -B "$branch" origin/main
  agent-git push -u origin "$branch"
fi

case "$PHASE" in
  implement|document)
    restore_agent_checkpoint "$ISSUE" "$PHASE" "$branch" "$MODE"
    ;;
  fix)
    clear_agent_checkpoint "$ISSUE"
    ;;
esac

echo "Prepared branch $branch for $PHASE"
