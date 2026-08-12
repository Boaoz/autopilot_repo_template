#!/usr/bin/env bash
# Lightweight watchdog for agent-goal issues.
#
# This script must stay short-running: it dispatches issue-specific workers and
# exits. The workers restore checkpoints and do the long implementation work.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"
MODE="${1:---poll}"
RUN_ID="${2:-${RECOVERY_RUN_ID:-}}"

usage() {
  echo "Usage: $0 --poll | --recover-run <run_id>" >&2
}

dispatch_agent_goal_issue() {
  local issue="$1" reason="${2:-watchdog}"

  echo "==> watchdog: dispatching issue #${issue} (${reason})"
  agent-gh workflow run agent-goal.yml \
    --repo "$REPO" \
    -f "issue_number=${issue}" \
    -f "phase=auto"
}

issue_has_live_lock() {
  local issue="$1"
  local lock_file
  lock_file="$(agent_machine_dir)/lock/issue-${issue}.lock"

  [[ -e "$lock_file" ]] || return 1
  if (
    flock -n 9
  ) 9>"$lock_file"; then
    return 1
  fi
  return 0
}

issue_needs_recovery() {
  local issue="$1"

  if issue_has_live_lock "$issue"; then
    echo "==> watchdog: issue #${issue}: worker lock is active"
    return 1
  fi

  [[ "$(has_label "$issue" "agent-goal" "$REPO")" == "true" ]] || return 1
  [[ "$(has_label "$issue" "agent-approved" "$REPO")" == "true" ]] || return 1

  # Do not auto-retry intentional stops, human questions, completed work, or
  # explicit failure states. /agent retry remains the recovery path for those.
  [[ "$(has_label "$issue" "agent-cancelled" "$REPO")" != "true" ]] || return 1
  [[ "$(has_label "$issue" "agent-question" "$REPO")" != "true" ]] || return 1
  [[ "$(has_label "$issue" "agent-failed" "$REPO")" != "true" ]] || return 1
  [[ "$(has_label "$issue" "agent-implemented" "$REPO")" != "true" ]] || return 1
  [[ "$(has_label "$issue" "agent-pr-open" "$REPO")" != "true" ]] || return 1

  return 0
}

recover_open_approved_issues() {
  local reason="$1"
  local issue dispatched=0

  mapfile -t issues < <(
    agent-gh issue list \
      --repo "$REPO" \
      --state open \
      --label agent-goal \
      --label agent-approved \
      --json number \
      --jq '.[].number'
  )

  for issue in "${issues[@]}"; do
    [[ -n "$issue" ]] || continue
    if issue_needs_recovery "$issue"; then
      dispatch_agent_goal_issue "$issue" "$reason"
      dispatched=$((dispatched + 1))
    else
      echo "==> watchdog: issue #${issue}: no recovery needed"
    fi
  done

  if [[ "$dispatched" -eq 0 ]]; then
    echo "No incomplete approved agent-goal issues need recovery."
  else
    echo "==> watchdog: dispatched ${dispatched} agent-goal worker run(s)."
  fi
}

case "$MODE" in
  --poll)
    recover_open_approved_issues "scheduled poll"
    ;;
  --recover-run)
    if [[ -z "$RUN_ID" ]]; then
      usage
      exit 2
    fi
    echo "==> watchdog: recovering after completed Agent goal run ${RUN_ID}"
    recover_open_approved_issues "run ${RUN_ID} completed without finishing"
    ;;
  *)
    usage
    exit 2
    ;;
esac
