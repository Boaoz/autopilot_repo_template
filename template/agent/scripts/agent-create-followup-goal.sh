#!/usr/bin/env bash
# Create at most one follow-up agent-goal issue for a completed agent-goal job.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

SOURCE_ISSUE="${1:-}"
TITLE="${2:-}"
BODY="${3:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"

if [[ -z "$SOURCE_ISSUE" || -z "$TITLE" || -z "$BODY" ]]; then
  echo "Usage: $0 <source-issue-number> <title> <body>" >&2
  exit 1
fi

case "$TITLE" in
  "[agent-goal]"*|"[Agent Goal]"*) ;;
  *) TITLE="[agent-goal] ${TITLE}" ;;
esac

state_dir="$(agent_goal_state_dir)"
run_key="${AGENT_FOLLOWUP_RUN_KEY:-issue-${SOURCE_ISSUE}-manual}"
run_key="$(printf '%s' "$run_key" | tr -c 'A-Za-z0-9_.-' '-')"
state_file="$state_dir/${run_key}-agent-followup-created"
mkdir -p "$state_dir"

if [[ -f "$state_file" ]]; then
  exit 0
fi

issue_body="$(cat <<EOF
Follow-up to #${SOURCE_ISSUE}.

${BODY}
EOF
)"

agent_gh_bin="${AGENT_GH_BIN:-agent-gh}"

url="$("$agent_gh_bin" issue create \
  --repo "$REPO" \
  --title "$TITLE" \
  --body "$issue_body" \
  --label agent-goal)"

printf '%s\n' "$url" | tee "$state_file"
