#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$REPO_ROOT/agent/scripts/run-agent-knowledge.sh"
ORCHESTRATOR="$REPO_ROOT/agent/scripts/agent-knowledge-orchestrator.sh"
KNOWLEDGE_WORKFLOW="$REPO_ROOT/.github/workflows/agent-knowledge.yml"
FIX_WORKFLOW="$REPO_ROOT/.github/workflows/agent-fix.yml"

require_text() {
  local file="$1" text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Missing expected text in ${file#$REPO_ROOT/}: $text" >&2
    exit 1
  fi
}

require_text "$RUNNER" "create_post_merge_fix_branch"
require_text "$RUNNER" "build_knowledge_post_merge_fix_pr_body"
require_text "$RUNNER" 'POST_MERGE_FIX=true'
require_text "$RUNNER" 'follow-up knowledge fix for issue #${ISSUE}'
require_text "$RUNNER" 'printf '\''%s\n'\'' "$LOG_FILE" > "$LOG_DIR/latest.log"'

log_line="$(grep -nF 'printf '\''%s\n'\'' "$LOG_FILE" > "$LOG_DIR/latest.log"' "$RUNNER" | head -n1 | cut -d: -f1)"
pr_lookup_line="$(grep -nF 'find_open_pr_for_knowledge_issue "$ISSUE" "$REPO"' "$RUNNER" | tail -n1 | cut -d: -f1)"
if [[ -z "$log_line" || -z "$pr_lookup_line" || "$log_line" -ge "$pr_lookup_line" ]]; then
  echo "knowledge latest.log must be initialized before fix PR lookup" >&2
  exit 1
fi

require_text "$ORCHESTRATOR" 'latest_human_fix_comment "$issue" "$REPO"'
require_text "$ORCHESTRATOR" '"$retry" == "true"'

require_text "$FIX_WORKFLOW" "pull_request_review_comment:"
if grep -Fq -- "pull_request_review_comment:" "$KNOWLEDGE_WORKFLOW"; then
  echo "PR review fixes must route only through agent-fix.yml" >&2
  exit 1
fi

echo "knowledge lifecycle checks OK"
