#!/usr/bin/env bash
# Acquire a per-issue lock, run one command in the prepared checkout, release lock.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

ISSUE=""
PR=""
WORKFLOW="agent"
RUN_ID="${AGENT_JOB_RUN_ID:-unknown}"
POLL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --workflow) WORKFLOW="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --poll) POLL=true; shift ;;
    --) shift; break ;;
    *) echo "agent-job-wrapper: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--issue N] [--pr N] [--workflow NAME] [--run-id ID] [--poll] -- <command...>" >&2
  exit 1
fi

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"
LOCK_DIR="$(agent_machine_dir)/lock"
mkdir -p "$LOCK_DIR"

resolve_target_issue() {
  if [[ -n "$ISSUE" ]]; then
    printf '%s' "$ISSUE"
    return 0
  fi
  if [[ -n "$PR" ]]; then
    local from_pr=""
    from_pr="$(resolve_knowledge_issue_from_pr "$PR" "$REPO" 2>/dev/null || true)"
    if [[ -n "$from_pr" ]]; then
      printf '%s' "$from_pr"
      return 0
    fi
    from_pr="$(resolve_issue_from_pr "$PR" "$REPO" 2>/dev/null || true)"
    if [[ -n "$from_pr" ]]; then
      printf '%s' "$from_pr"
      return 0
    fi
  fi
  return 1
}

set_github_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${key}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

TARGET_ISSUE="$(resolve_target_issue 2>/dev/null || true)"
LOCK_SUFFIX="${TARGET_ISSUE:-poll}"
LOCK_FILE="$LOCK_DIR/issue-${LOCK_SUFFIX}.lock"
INFO_FILE="$LOCK_DIR/issue-${LOCK_SUFFIX}.info"

write_lock_info() {
  cat > "$INFO_FILE" <<EOF
issue=${ISSUE:-$TARGET_ISSUE}
pr=${PR:-}
workflow=${WORKFLOW}
run_id=${RUN_ID}
pid=$$
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

clear_lock_info() {
  rm -f "$INFO_FILE"
}

release_lock() {
  clear_lock_info
  flock -u 200 2>/dev/null || true
}

handle_busy() {
  set_github_output "proceed" "false"
  set_github_output "skip_reason" "busy"

  if [[ -z "$TARGET_ISSUE" ]]; then
    echo "==> agent is busy; no target issue for busy comment."
    exit 0
  fi

  if [[ -n "${COMMENT_ID:-}" ]] && busy_comment_already_posted "$COMMENT_ID"; then
    echo "==> agent is busy; busy comment already posted for comment ${COMMENT_ID}."
    exit 0
  fi

  post_agent_busy_comment "$TARGET_ISSUE" "$REPO" "$(read_agent_lock_info "$INFO_FILE")"
  if [[ -n "${COMMENT_ID:-}" ]]; then
    mark_busy_comment_posted "$COMMENT_ID" "$TARGET_ISSUE"
  fi
  exit 0
}

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  handle_busy
fi

trap release_lock EXIT

write_lock_info
set_github_output "proceed" "true"
set_github_output "skip_reason" ""

echo "==> Running: $*"
"$@"
