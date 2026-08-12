#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/agent-cancel.yml"
SCRIPT="$REPO_ROOT/agent/scripts/agent-cancel-issue.sh"
GOAL_WORKFLOW="$REPO_ROOT/.github/workflows/agent-goal.yml"
KNOWLEDGE_WORKFLOW="$REPO_ROOT/.github/workflows/agent-knowledge.yml"

require_text() {
  local file="$1" text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Missing expected text in ${file#$REPO_ROOT/}: $text" >&2
    exit 1
  fi
}

[[ -x "$SCRIPT" ]]

require_text "$WORKFLOW" "name: Agent cancel"
require_text "$WORKFLOW" "issue_comment:"
require_text "$WORKFLOW" "startsWith(github.event.comment.body, '/agent cancel')"
require_text "$WORKFLOW" "contains(github.event.issue.labels.*.name, 'agent-goal')"
require_text "$WORKFLOW" "contains(github.event.issue.labels.*.name, 'agent-knowledge')"
require_text "$WORKFLOW" "cancel-inspect:"
require_text "$WORKFLOW" "contains(github.event.issue.labels.*.name, 'agent-inspect')"
require_text "$WORKFLOW" "group: agent-inspect-\${{ github.event.issue.number }}"
require_text "$WORKFLOW" "cancel-in-progress: true"
require_text "$WORKFLOW" "group: agent-cancel-\${{ startsWith(github.event.comment.body, '/agent cancel') && github.event.issue.number || github.run_id }}"
require_text "$WORKFLOW" "./agent/scripts/agent-cancel-issue.sh"
if grep -Fq -- "agent-job-wrapper" "$WORKFLOW"; then
  echo "agent-cancel workflow must not use the normal issue lock wrapper" >&2
  exit 1
fi

require_text "$SCRIPT" "agent-cancelled"
require_text "$SCRIPT" "run_id="
require_text "$SCRIPT" "agent-gh run cancel"
require_text "$SCRIPT" "Cancellation requested"

if grep -Fq -- "startsWith(github.event.comment.body, '/agent cancel')" "$GOAL_WORKFLOW" ||
  grep -Fq -- "contains(github.event.comment.body, '/agent cancel')" "$GOAL_WORKFLOW"; then
  echo "agent-goal workflow should not route /agent cancel through the slow worker lane" >&2
  exit 1
fi

if grep -Fq -- "startsWith(github.event.comment.body, '/agent cancel')" "$KNOWLEDGE_WORKFLOW" ||
  grep -Fq -- "contains(github.event.comment.body, '/agent cancel')" "$KNOWLEDGE_WORKFLOW"; then
  echo "agent-knowledge workflow should not route /agent cancel through the slow worker lane" >&2
  exit 1
fi

echo "agent fast cancel checks OK"
