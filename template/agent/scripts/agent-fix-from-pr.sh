#!/usr/bin/env bash
# Route /agent fix on a pull request to the correct agent orchestrator.
#
# Usage: ./agent/scripts/agent-fix-from-pr.sh <pr_number>
#
# Requires env:
#   COMMENT_BODY — human feedback containing /agent fix
#   COMMENT_ID   — optional, for deduplication

set -euo pipefail

PR_NUM="${1:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

if [[ -z "$PR_NUM" ]]; then
  echo "Usage: $0 <pr_number>" >&2
  exit 1
fi

cd "$REPO_ROOT"

# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
  echo "==> PR #${PR_NUM}: comment author is configured agent, skipping"
  exit 0
fi

BRANCH="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq .headRefName)"
export PR_NUMBER="$PR_NUM"

export REVISION_COMMENT="$(strip_fix_feedback "${COMMENT_BODY:-}")"
if [[ -z "$REVISION_COMMENT" ]]; then
  export REVISION_COMMENT="${COMMENT_BODY:-}"
fi

case "$BRANCH" in
  agent/knowledge-issue-*)
    ISSUE_NUM="$(resolve_knowledge_issue_from_pr "$PR_NUM" "$REPO")"
    if [[ -z "$ISSUE_NUM" ]]; then
      echo "Could not resolve knowledge issue from PR #${PR_NUM} (branch: ${BRANCH})" >&2
      exit 1
    fi
    echo "==> PR #${PR_NUM}: knowledge fix for issue #${ISSUE_NUM}"
    exec "$REPO_ROOT/agent/scripts/agent-knowledge-orchestrator.sh" --from-pr "$PR_NUM"
    ;;
  agent/issue-*)
    ISSUE_NUM="$(resolve_issue_from_pr "$PR_NUM" "$REPO")"
    if [[ -z "$ISSUE_NUM" ]]; then
      echo "Could not resolve goal issue from PR #${PR_NUM} (branch: ${BRANCH})" >&2
      exit 1
    fi
    echo "==> PR #${PR_NUM}: goal fix for issue #${ISSUE_NUM}"
    exec "$REPO_ROOT/agent/scripts/agent-goal-orchestrator.sh" --from-pr "$PR_NUM"
    ;;
  *)
    echo "PR #${PR_NUM} branch '${BRANCH}' is not an agent branch." >&2
    exit 1
    ;;
esac
