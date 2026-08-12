#!/usr/bin/env bash
# Decide and run the next agent-knowledge phase for one issue (or poll all open issues).
#
# Usage:
#   ./agent/scripts/agent-knowledge-orchestrator.sh <issue_number>
#   ./agent/scripts/agent-knowledge-orchestrator.sh --poll
#   ./agent/scripts/agent-knowledge-orchestrator.sh --from-pr <pr_number>

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

  if [[ "$(has_label "$issue" "agent-knowledge" "$REPO")" != "true" ]]; then
    echo "skip"
    return
  fi

  if [[ -n "${COMMENT_BODY:-}" ]] && is_fix_comment "$COMMENT_BODY"; then
    if [[ "$(has_label "$issue" "agent-pr-open" "$REPO")" == "true" || \
          "$(has_label "$issue" "agent-documented" "$REPO")" == "true" ]]; then
      echo "fix"
      return
    fi
  fi

  if [[ "$retry" == "true" && \
        ( "$(has_label "$issue" "agent-pr-open" "$REPO")" == "true" || \
          "$(has_label "$issue" "agent-documented" "$REPO")" == "true" ) ]]; then
    echo "fix"
    return
  fi

  if [[ "$(has_label "$issue" "agent-documented" "$REPO")" == "true" ]]; then
    echo "skip"
    return
  fi

  if [[ "$retry" != "true" && "$(has_label "$issue" "agent-failed" "$REPO")" == "true" ]]; then
    echo "skip"
    return
  fi

  if [[ "$retry" != "true" && -n "${COMMENT_BODY:-}" ]]; then
    if is_agent_slash_command "$COMMENT_BODY"; then
      echo "skip"
      return
    fi
  fi

  echo "document"
}

run_phase() {
  local issue="$1" phase="$2"

  echo "==> knowledge issue #${issue}: running phase '${phase}'"

  case "$phase" in
    cancel)
      mark_agent_cancelled "$issue" "$REPO"
      return 0
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
    *)
      unset REVISION_COMMENT
      ;;
  esac

  if [[ "$phase" == "cancel" ]]; then
    return 0
  fi

  if "$REPO_ROOT/agent/scripts/run-agent-knowledge.sh" "$phase" "$issue"; then
    clear_agent_failed "$issue" "$REPO"

    case "$phase" in
      document)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-documented"
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-pr-open"
        ;;
      fix)
        agent_gh_issue_edit "$issue" --repo "$REPO" --add-label "agent-pr-updated"
        ;;
    esac
    return 0
  fi

  mark_agent_failed "$issue" "$REPO" "$phase" "$(latest_agent_log "$issue")"
  return 1
}

process_issue() {
  local issue="$1"
  local phase

  if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
    echo "==> knowledge issue #${issue}: comment author is configured agent, skipping"
    return 0
  fi

  if [[ -n "${COMMENT_ID:-}" ]] && comment_already_processed "$issue" "$COMMENT_ID"; then
    echo "==> knowledge issue #${issue}: comment ${COMMENT_ID} already processed, skipping"
    return 0
  fi

  phase="$(detect_phase "$issue")"

  if [[ "$phase" == "skip" ]]; then
    echo "==> knowledge issue #${issue}: nothing to do"
    return 0
  fi

  if run_phase "$issue" "$phase"; then
    if [[ -n "${COMMENT_ID:-}" ]]; then
      mark_comment_processed "$issue" "$COMMENT_ID" "$phase"
    fi
  fi
}

if [[ "${1:-}" == "--poll" ]]; then
  unset COMMENT_BODY COMMENT_ID
  mapfile -t issues < <(agent-gh issue list --repo "$REPO" --label agent-knowledge --state open --json number --jq '.[].number')
  if [[ ${#issues[@]} -eq 0 ]]; then
    echo "No open agent-knowledge issues."
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
  ISSUE_NUM="$(resolve_knowledge_issue_from_pr "$PR_NUM" "$REPO")"
  if [[ -z "$ISSUE_NUM" ]]; then
    echo "Could not resolve issue number from PR #${PR_NUM}" >&2
    exit 1
  fi
  export PR_NUMBER="$PR_NUM"

  if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
    echo "==> knowledge PR #${PR_NUM}: comment author is configured agent, skipping"
    exit 0
  fi

  if [[ -n "${COMMENT_ID:-}" ]] && comment_already_processed "$ISSUE_NUM" "$COMMENT_ID"; then
    echo "==> knowledge issue #${ISSUE_NUM}: comment ${COMMENT_ID} already processed, skipping"
    exit 0
  fi

  export REVISION_COMMENT="$(strip_fix_feedback "${COMMENT_BODY:-}")"
  if [[ -z "$REVISION_COMMENT" ]]; then
    export REVISION_COMMENT="${COMMENT_BODY:-}"
  fi

  if run_phase "$ISSUE_NUM" fix; then
    if [[ -n "${COMMENT_ID:-}" ]]; then
      mark_comment_processed "$ISSUE_NUM" "$COMMENT_ID" fix
    fi
    exit 0
  fi
  exit 1
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <issue_number> | --poll | --from-pr <pr_number>" >&2
  exit 1
fi

process_issue "$1"
