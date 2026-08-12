#!/usr/bin/env bash
# Fast cancellation path for agent-goal, agent-knowledge, and agent-inspect issues.
#
# This intentionally bypasses agent-job-wrapper so a cancel request is not
# blocked by the per-issue worker lock held by the job it is trying to stop.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"

if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
  echo "==> cancel: comment author is configured agent, skipping"
  exit 0
fi

read_lock_value() {
  local info_file="$1" key="$2"
  [[ -f "$info_file" ]] || return 1
  grep -E "^${key}=" "$info_file" | tail -n 1 | cut -d= -f2- | tr -d '\r'
}

cancel_active_run_from_lock() {
  local issue="$1"
  local info_file run_id current_run_id

  info_file="$(agent_machine_dir)/lock/issue-${issue}.info"
  run_id="$(read_lock_value "$info_file" "run_id" 2>/dev/null || true)"
  current_run_id="${GITHUB_RUN_ID:-}"

  if [[ -z "$run_id" || "$run_id" == "unknown" ]]; then
    echo "==> cancel: no active run id recorded for issue #${issue}"
    return 0
  fi
  if [[ -n "$current_run_id" && "$run_id" == "$current_run_id" ]]; then
    echo "==> cancel: refusing to cancel current cancel workflow run ${run_id}"
    return 0
  fi

  echo "==> cancel: cancelling active agent run ${run_id} for issue #${issue}"
  agent-gh run cancel "$run_id" --repo "$REPO" || true
}

agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "agent-cancelled"
agent_gh_issue_edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "agent-failed"

cancel_active_run_from_lock "$ISSUE_NUMBER"

agent-gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$(cat <<EOF
## Cancellation requested

I marked this issue with \`agent-cancelled\` and requested cancellation of any active agent run recorded for this issue.

Automation will not resume this issue while \`agent-cancelled\` is present.
EOF
)"
