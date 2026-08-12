#!/usr/bin/env bash
# Invoked by .github/workflows/agent-knowledge.yml (issue / workflow_dispatch).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER required}"
FORCE_PHASE="${FORCE_PHASE:-auto}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"

if [[ "$FORCE_PHASE" != "auto" ]]; then
  if [[ "$FORCE_PHASE" == "fix" ]]; then
    export REVISION_COMMENT="$(strip_fix_feedback "${COMMENT_BODY:-}")"
    if [[ -z "$REVISION_COMMENT" ]]; then
      export REVISION_COMMENT="${COMMENT_BODY:-}"
    fi
  else
    unset REVISION_COMMENT
  fi

  if "$REPO_ROOT/agent/scripts/run-agent-knowledge.sh" "$FORCE_PHASE" "$ISSUE_NUMBER"; then
    clear_agent_failed "$ISSUE_NUMBER" "$REPO"
    case "$FORCE_PHASE" in
      document)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-documented"
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-pr-open"
        ;;
      fix)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-pr-updated"
        ;;
    esac
  else
    mark_agent_failed "$ISSUE_NUMBER" "$REPO" "$FORCE_PHASE" \
      "${AGENT_GOAL_LOG_FILE:-unknown.jsonl}"
    exit 1
  fi
else
  "$REPO_ROOT/agent/scripts/agent-knowledge-orchestrator.sh" "$ISSUE_NUMBER"
fi
