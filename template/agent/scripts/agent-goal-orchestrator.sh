#!/usr/bin/env bash
# Decide and run the next agent-goal phase for one issue (or poll all open issues).
#
# Usage:
#   ./agent/scripts/agent-goal-orchestrator.sh <issue_number>
#   ./agent/scripts/agent-goal-orchestrator.sh --poll
#   ./agent/scripts/agent-goal-orchestrator.sh --from-pr <pr_number>
#
# Optional env:
#   COMMENT_BODY — human comment that triggered this run
#   COMMENT_ID   — GitHub comment id (deduplication)
#   PR_NUMBER    — pull request number (fix phase)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

cd "$REPO_ROOT"

# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

detect_phase() {
  local issue="$1"
  local retry=false

  if [[ -n "${COMMENT_BODY:-}" ]] && is_retry_comment "$COMMENT_BODY"; then
    retry=true
    clear_agent_cancelled "$issue" "$REPO"
    clear_agent_failed "$issue" "$REPO"
  fi

  if [[ "$(has_label "$issue" "agent-cancelled" "$REPO")" == "true" ]]; then
    echo "skip"
    return
  fi

  if [[ "$(has_label "$issue" "agent-goal" "$REPO")" != "true" ]]; then
    echo "skip"
    return
  fi

  if [[ -n "${COMMENT_BODY:-}" ]] && is_cancel_comment "$COMMENT_BODY"; then
    echo "cancel"
    return
  fi

  if [[ -n "${COMMENT_BODY:-}" ]] && is_fix_comment "$COMMENT_BODY"; then
    if [[ "$(has_label "$issue" "agent-pr-open" "$REPO")" == "true" || \
          "$(has_label "$issue" "agent-implemented" "$REPO")" == "true" ]]; then
      echo "fix"
      return
    fi
  fi

  if [[ -n "${COMMENT_BODY:-}" ]] && is_answer_comment "$COMMENT_BODY"; then
    if [[ "$(has_label "$issue" "agent-question" "$REPO")" == "true" ]]; then
      local pending_phase
      pending_phase="$(read_agent_clarification_phase "$issue")"
      if [[ -n "$pending_phase" ]]; then
        echo "$pending_phase"
        return
      fi
    fi
  fi

  if [[ "$retry" != "true" && "$(has_label "$issue" "agent-failed" "$REPO")" == "true" ]]; then
    echo "skip"
    return
  fi

  if [[ "$retry" == "true" && \
        ( "$(has_label "$issue" "agent-pr-open" "$REPO")" == "true" || \
          "$(has_label "$issue" "agent-implemented" "$REPO")" == "true" ) ]]; then
    echo "fix"
    return
  fi

  if [[ "$(has_label "$issue" "agent-implemented" "$REPO")" == "true" ]]; then
    echo "skip"
    return
  fi

  if [[ "$retry" != "true" && -n "${COMMENT_BODY:-}" ]]; then
    if is_approve_comment "$COMMENT_BODY"; then
      echo "implement"
      return
    fi
    if is_revise_comment "$COMMENT_BODY"; then
      if [[ "$(has_label "$issue" "agent-plan-posted" "$REPO")" == "true" ]]; then
        echo "revise"
        return
      fi
      echo "skip"
      return
    fi
    if is_agent_slash_command "$COMMENT_BODY"; then
      echo "skip"
      return
    fi
  fi

  if [[ "$(has_label "$issue" "agent-approved" "$REPO")" == "true" ]]; then
    echo "implement"
    return
  fi

  if [[ "$(has_label "$issue" "agent-plan-posted" "$REPO")" != "true" ]]; then
    echo "plan"
    return
  fi

  echo "skip"
}

run_phase() {
  local issue="$1" phase="$2"

  echo "==> issue #${issue}: running phase '${phase}'"

  case "$phase" in
    cancel)
      mark_agent_cancelled "$issue" "$REPO"
      return 0
      ;;
    revise)
      export REVISION_COMMENT="$(strip_revise_feedback "${COMMENT_BODY:-}")"
      ;;
    fix)
      export REVISION_COMMENT="$(strip_fix_feedback "${COMMENT_BODY:-}")"
      if is_retry_comment "${COMMENT_BODY:-}"; then
        export REVISION_COMMENT="$(latest_human_fix_comment "$issue" "$REPO")"
      fi
      if [[ -z "$REVISION_COMMENT" ]]; then
        export REVISION_COMMENT="${COMMENT_BODY:-}"
      fi
      ;;
    implement)
      export REVISION_COMMENT=""
      ;;
    *)
      export REVISION_COMMENT="${COMMENT_BODY:-}"
      ;;
  esac

  if [[ -n "${COMMENT_BODY:-}" ]] && is_answer_comment "$COMMENT_BODY"; then
    export REVISION_COMMENT="$(strip_answer_feedback "${COMMENT_BODY:-}")"
  fi

  if [[ "$phase" == "cancel" ]]; then
    return 0
  fi

  set +e
  "$REPO_ROOT/agent/scripts/run-agent-goal.sh" "$phase" "$issue"
  phase_status=$?
  set -e

  if [[ "$phase_status" -eq 0 ]]; then
    clear_agent_failed "$issue" "$REPO"
    if [[ "$phase" == "plan" || "$phase" == "implement" ]]; then
      clear_agent_clarification "$issue"
      agent_gh_issue_edit "$issue" --repo "$REPO" --remove-label "agent-question"
    fi

    case "$phase" in
      plan)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-plan-posted"
        ;;
      revise)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-plan-revised"
        ;;
      implement)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-implemented"
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-pr-open"
        ;;
      fix)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-pr-updated"
        ;;
    esac
    return 0
  fi

  if [[ ( "$phase" == "plan" || "$phase" == "implement" ) && "$phase_status" -eq 20 ]]; then
    local question
    question="$(extract_agent_question_from_log "$(latest_agent_log "$issue")" || true)"
    if [[ -n "$question" ]]; then
      write_agent_clarification_question "$issue" "$phase" "$question"
      post_agent_clarification_question "$issue" "$REPO" "$phase" "$question" "$(latest_agent_log "$issue")"
      mark_comment_processed "$issue" "${COMMENT_ID:-}" "$phase"
      return 0
    fi
  fi

  mark_agent_failed "$issue" "$REPO" "$phase" "$(latest_agent_log "$issue")"
  return 1
}

process_issue() {
  local issue="$1"
  local phase

  if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
    echo "==> issue #${issue}: comment author is configured agent, skipping"
    return 0
  fi

  if [[ -n "${COMMENT_ID:-}" ]] && comment_already_processed "$issue" "$COMMENT_ID"; then
    echo "==> issue #${issue}: comment ${COMMENT_ID} already processed, skipping"
    return 0
  fi

  phase="$(detect_phase "$issue")"

  if [[ "$phase" == "skip" ]]; then
    echo "==> issue #${issue}: nothing to do"
    return 0
  fi

  if [[ "$phase" == "implement" && "$(has_label "$issue" "agent-approved" "$REPO")" != "true" ]]; then
    agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-approved"
  fi

  if run_phase "$issue" "$phase"; then
    if [[ -n "${COMMENT_ID:-}" ]]; then
      mark_comment_processed "$issue" "$COMMENT_ID" "$phase"
    fi
  fi
}

if [[ "${1:-}" == "--poll" ]]; then
  unset COMMENT_BODY COMMENT_ID PR_NUMBER
  mapfile -t issues < <(agent-gh issue list --repo "$REPO" --label agent-goal --state open --json number --jq '.[].number')
  if [[ ${#issues[@]} -eq 0 ]]; then
    echo "No open agent-goal issues."
    exit 0
  fi
  for issue in "${issues[@]}"; do
    process_issue "$issue" || true
  done
  exit 0
fi

if [[ "${1:-}" == "--from-pr" ]]; then
  PR_NUM="${2:-}"
  if [[ -z "$PR_NUM" ]]; then
    echo "Usage: $0 --from-pr <pr_number>" >&2
    exit 1
  fi
  ISSUE_NUM="$(resolve_issue_from_pr "$PR_NUM" "$REPO")"
  if [[ -z "$ISSUE_NUM" ]]; then
    echo "Could not resolve issue number from PR #${PR_NUM}" >&2
    exit 1
  fi
  export PR_NUMBER="$PR_NUM"
  process_issue "$ISSUE_NUM"
  exit 0
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <issue_number> | --poll | --from-pr <pr_number>" >&2
  exit 1
fi

process_issue "$1"
