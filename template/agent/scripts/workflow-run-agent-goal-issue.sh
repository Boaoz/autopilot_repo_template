#!/usr/bin/env bash
# Invoked by .github/workflows/agent-goal.yml (issue / workflow_dispatch).

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
  export REVISION_COMMENT=""
  if [[ "$FORCE_PHASE" == "revise" ]]; then
    export REVISION_COMMENT="$(strip_revise_feedback "${COMMENT_BODY:-}")"
  elif [[ "$FORCE_PHASE" == "fix" ]]; then
    export REVISION_COMMENT="$(strip_fix_feedback "${COMMENT_BODY:-}")"
  elif is_answer_comment "${COMMENT_BODY:-}"; then
    export REVISION_COMMENT="$(strip_answer_feedback "${COMMENT_BODY:-}")"
  elif [[ "$FORCE_PHASE" == "plan" ]]; then
    export REVISION_COMMENT="${COMMENT_BODY:-}"
  fi
  set +e
  "$REPO_ROOT/agent/scripts/run-agent-goal.sh" "$FORCE_PHASE" "$ISSUE_NUMBER"
  phase_status=$?
  set -e

  if [[ "$phase_status" -eq 0 ]]; then
    clear_agent_failed "$ISSUE_NUMBER" "$REPO"
    if [[ "$FORCE_PHASE" == "plan" || "$FORCE_PHASE" == "implement" ]]; then
      clear_agent_clarification "$ISSUE_NUMBER"
      agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "agent-question"
    fi
    case "$FORCE_PHASE" in
      plan)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-plan-posted"
        ;;
      revise)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-plan-revised"
        ;;
      implement)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-approved"
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-implemented"
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-pr-open"
        ;;
      fix)
        agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-pr-updated"
        ;;
    esac
  elif [[ ( "$FORCE_PHASE" == "plan" || "$FORCE_PHASE" == "implement" ) && "$phase_status" -eq 20 ]]; then
    question="$(extract_agent_question_from_log "${AGENT_GOAL_LOG_FILE:-$(latest_agent_log "$ISSUE_NUMBER")}" || true)"
    if [[ -n "$question" ]]; then
      write_agent_clarification_question "$ISSUE_NUMBER" "$FORCE_PHASE" "$question"
      post_agent_clarification_question "$ISSUE_NUMBER" "$REPO" "$FORCE_PHASE" "$question" \
        "${AGENT_GOAL_LOG_FILE:-$(latest_agent_log "$ISSUE_NUMBER")}"
      exit 0
    fi
    mark_agent_failed "$ISSUE_NUMBER" "$REPO" "$FORCE_PHASE" \
      "${AGENT_GOAL_LOG_FILE:-unknown.jsonl}" \
      "Agent requested clarification, but no question could be extracted."
    exit 1
  else
    mark_agent_failed "$ISSUE_NUMBER" "$REPO" "$FORCE_PHASE" \
      "${AGENT_GOAL_LOG_FILE:-unknown.jsonl}"
    exit 1
  fi
else
  "$REPO_ROOT/agent/scripts/agent-goal-orchestrator.sh" "$ISSUE_NUMBER"
fi
