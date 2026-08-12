#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
GOAL_RUNNER="$REPO_ROOT/agent/scripts/run-agent-goal.sh"
KNOWLEDGE_RUNNER="$REPO_ROOT/agent/scripts/run-agent-knowledge.sh"

# shellcheck source=/dev/null
source "$LIB"

agent-gh() {
  local jq_filter="${*: -1}"
  case "$*" in
    "issue view "*)
      jq -r "$jq_filter" <<'JSON'
{"body":null,"author":{"login":"human"},"comments":[{"author":{"login":"agent"},"createdAt":"2026-07-13T08:00:00Z","body":"prior agent answer"},{"author":{"login":"human"},"createdAt":"2026-07-13T08:01:00Z","body":"follow-up question"}]}
JSON
      ;;
    "pr view 17 "*)
      jq -r "$jq_filter" <<'JSON'
{"title":"Proposed fix","url":"https://example.test/pr/17","body":null,"author":{"login":"agent"},"comments":[{"author":{"login":"human"},"createdAt":"2026-07-13T08:02:00Z","body":"PR comment"}],"reviews":[{"author":{"login":"reviewer"},"submittedAt":null,"state":"COMMENTED","body":null}]}
JSON
      ;;
    "api --paginate repos/example/repo/pulls/17/comments --jq "*)
      jq -r "$jq_filter" <<'JSON'
[{"user":{"login":"reviewer"},"created_at":"2026-07-13T08:03:00Z","path":"src/example.py","line":null,"original_line":12,"body":"inline review comment"}]
JSON
      ;;
    *) echo "unexpected agent-gh invocation: $*" >&2; return 1 ;;
  esac
}

context="$(build_fix_conversation_context 15 example/repo 17)"
grep -Fq 'prior agent answer' <<< "$context"
grep -Fq 'follow-up question' <<< "$context"
grep -Fq 'PR comment' <<< "$context"
grep -Fq 'Review by reviewer at unknown time [COMMENTED]:' <<< "$context"
grep -Fq 'inline review comment' <<< "$context"

REPO=example/repo
inspect_context="$(read_inspect_conversation 15)"
grep -Fq 'prior agent answer' <<< "$inspect_context"
grep -Fq 'follow-up question' <<< "$inspect_context"

grep -Fq 'FIX_CONVERSATION_CONTEXT="$(build_fix_conversation_context' "$GOAL_RUNNER"
grep -Fq 'FIX_CONVERSATION_CONTEXT="$(build_fix_conversation_context' "$KNOWLEDGE_RUNNER"
grep -Fq 'find_latest_pr_for_issue' "$GOAL_RUNNER"
grep -Fq 'find_latest_pr_for_knowledge_issue' "$KNOWLEDGE_RUNNER"
grep -Fq 'Complete source issue and pull request conversation context:' "$GOAL_RUNNER"
grep -Fq 'Complete source issue and pull request conversation context:' "$KNOWLEDGE_RUNNER"

echo "fix conversation context checks OK"
