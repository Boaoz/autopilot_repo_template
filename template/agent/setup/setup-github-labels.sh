#!/usr/bin/env bash
# Create GitHub labels required by agent workflows.
#
# Usage: ./agent/setup/setup-github-labels.sh [owner/repo]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

REPO="${1:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}}"

create_label() {
  local name="$1" description="$2" color="$3"
  if agent-gh api "repos/${REPO}/labels/${name}" >/dev/null 2>&1; then
    echo "  ok  ${name} (exists)"
    return 0
  fi
  agent-gh api -X POST "repos/${REPO}/labels" \
    -f name="$name" -f description="$description" -f color="$color" >/dev/null
  echo "  +   ${name}"
}

echo "Ensuring agent labels on ${REPO}..."

create_label agent-goal "Task for agent (code)" 0E8A16
create_label agent-knowledge "Explore and document reusable knowledge" 5319E7
create_label agent-inspect "Read-only repository conversation" 0969DA
create_label agent-plan-posted "Agent workflow state" 1D76DB
create_label agent-plan-revised "Agent revised plan after human feedback" FBCA04
create_label agent-question "Agent is waiting for a human clarification answer" D4C5F9
create_label agent-approved "Agent workflow state" 1D76DB
create_label agent-implemented "Agent workflow state" 1D76DB
create_label agent-documented "Knowledge guide published" C5DEF5
create_label agent-pr-open "Agent draft PR open" FEF2C0
create_label agent-pr-updated "Agent PR updated after review" FEF2C0
create_label agent-failed "Agent workflow failed" B60205
create_label agent-cancelled "Agent automation cancelled" EDEDED

echo "Done."
