#!/usr/bin/env bash
# Answer read-only inspection questions without modifying repository state.
#
# Usage: ./agent/scripts/agent-inspect.sh [pr_number]
#
# Requires env:
#   COMMENT_BODY — human question or conversational inspect comment
#   COMMENT_ID   — optional, for deduplication
#   ISSUE_NUMBER — source issue number when invoked from an issue
#   INSPECT_ISSUE_MODE — true for a conversational agent-inspect issue

set -euo pipefail

PR_NUM="${1:-}"
INSPECT_ISSUE_MODE="${INSPECT_ISSUE_MODE:-false}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT

# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-python-env.sh
source "$REPO_ROOT/agent/scripts/agent-python-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

cd "$REPO_ROOT"

if comment_author_is_agent "${COMMENT_AUTHOR:-}"; then
  echo "==> comment author is configured agent, skipping"
  exit 0
fi

resolve_pr_for_issue() {
  local issue="$1" repo="$2" pr=""
  pr="$(find_open_pr_for_issue "$issue" "$repo" 2>/dev/null || true)"
  if [[ -z "$pr" ]]; then
    pr="$(find_open_pr_for_knowledge_issue "$issue" "$repo" 2>/dev/null || true)"
  fi
  printf '%s' "$pr"
}

if [[ "$INSPECT_ISSUE_MODE" != "true" && -z "$PR_NUM" && -n "${ISSUE_NUMBER:-}" ]]; then
  PR_NUM="$(resolve_pr_for_issue "$ISSUE_NUMBER" "$REPO")"
fi

COMMENT_TARGET="${ISSUE_NUMBER:-}"
if [[ -z "$COMMENT_TARGET" && -n "$PR_NUM" ]]; then
  COMMENT_TARGET="$PR_NUM"
fi
if [[ -z "$COMMENT_TARGET" ]]; then
  echo "Could not resolve issue or PR comment target." >&2
  exit 1
fi

if [[ -n "${COMMENT_ID:-}" ]] && comment_already_processed "$COMMENT_TARGET" "$COMMENT_ID"; then
  echo "==> inspect comment ${COMMENT_ID} already processed"
  exit 0
fi

if [[ "$INSPECT_ISSUE_MODE" != "true" && -z "$PR_NUM" ]]; then
  agent-gh issue comment "$COMMENT_TARGET" --repo "$REPO" --body "$(cat <<EOF
I could not find an open agent pull request for this issue to inspect.
EOF
)"
  mark_comment_processed "$COMMENT_TARGET" "${COMMENT_ID:-}" "inspect"
  exit 0
fi

QUESTION=""
CONVERSATION="$(read_inspect_conversation "$COMMENT_TARGET")"
TARGET_REF="origin/main"
SUBJECT_CONTEXT="Repository-wide conversational inspection of current main and pull requests."

if [[ "$INSPECT_ISSUE_MODE" == "true" ]]; then
  ISSUE_TITLE="$(agent-gh issue view "$COMMENT_TARGET" --repo "$REPO" --json title --jq .title)"
  ISSUE_URL="$(agent-gh issue view "$COMMENT_TARGET" --repo "$REPO" --json url --jq .url)"
  ISSUE_BODY="$(agent-gh issue view "$COMMENT_TARGET" --repo "$REPO" --json body --jq '.body // ""')"
  if [[ -n "${COMMENT_BODY:-}" ]] && ! is_retry_comment "$COMMENT_BODY"; then
    QUESTION="$COMMENT_BODY"
  elif [[ -n "${COMMENT_BODY:-}" ]] && is_retry_comment "$COMMENT_BODY"; then
    clear_agent_cancelled "$COMMENT_TARGET" "$REPO"
    QUESTION="$(agent-gh issue view "$COMMENT_TARGET" --repo "$REPO" --comments --json comments --jq '
      [.comments[] | select(.author.login != "'"$(agent_github_user)"'") | .body
       | select((ascii_downcase | startswith("/agent retry")) | not)
       | select((ascii_downcase | startswith("/agent cancel")) | not)] | last // empty
    ')"
  fi
  if [[ -z "$QUESTION" ]]; then
    QUESTION="$ISSUE_BODY"
  fi
  SUBJECT_CONTEXT="Inspect issue #${COMMENT_TARGET}: ${ISSUE_TITLE}\nIssue URL: ${ISSUE_URL}\nUse the complete conversation below as context."
else
  QUESTION="$(strip_inspect_question "${COMMENT_BODY:-}")"
  if [[ -z "$QUESTION" ]]; then
    QUESTION="Summarize the current status of this pull request, including what it changes, what remains uncertain, and any notable risks."
  fi

  BRANCH="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq .headRefName)"
  BASE_BRANCH="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json baseRefName --jq .baseRefName)"
  PR_TITLE="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json title --jq .title)"
  PR_URL="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json url --jq .url)"
  PR_BODY="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body // ""')"

  case "$BRANCH" in
    agent/issue-* | agent/knowledge-issue-*) ;;
    *)
      agent-gh issue comment "$COMMENT_TARGET" --repo "$REPO" --body "$(cat <<EOF
I found PR #${PR_NUM}, but its branch \`${BRANCH}\` is not an agent branch, so I did not inspect it.
EOF
)"
      mark_comment_processed "$COMMENT_TARGET" "${COMMENT_ID:-}" "inspect"
      exit 0
      ;;
  esac
  TARGET_REF="origin/$BRANCH"
  SUBJECT_CONTEXT="Pull request: #${PR_NUM} ${PR_URL}\nTitle: ${PR_TITLE}\nBase branch: ${BASE_BRANCH}\nHead branch: ${BRANCH}\n\nPR description:\n${PR_BODY}"
fi

run_dir="$(agent_goal_issue_run_dir "$COMMENT_TARGET")/inspect-${COMMENT_ID:-manual-$(date -u +%Y%m%dT%H%M%SZ)}"
worktree="$run_dir/worktree"
log_file="$run_dir/inspect.log"
answer_file="$run_dir/answer.md"
mkdir -p "$run_dir"

cleanup() {
  if [[ -d "$worktree/.git" || -f "$worktree/.git" ]]; then
    agent-git worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

retry_readonly_git() {
  local description="$1"
  shift

  local attempt
  for attempt in 1 2 3; do
    if "$@" >/dev/null; then
      return 0
    fi
    if [[ "$attempt" -eq 3 ]]; then
      echo "Failed ${description} after ${attempt} attempts." >&2
      return 1
    fi
    echo "Retrying ${description} after transient failure (attempt ${attempt}/3)." >&2
    sleep $((attempt * 5))
  done
}

if [[ "$INSPECT_ISSUE_MODE" == "true" ]]; then
  retry_readonly_git "fetching main" agent-git fetch origin main:refs/remotes/origin/main
else
  retry_readonly_git "fetching PR branch" agent-git fetch origin "$BRANCH:refs/remotes/origin/$BRANCH"
fi
retry_readonly_git "creating read-only worktree" agent-git worktree add --detach "$worktree" "$TARGET_REF"

agent_python_env_activate

prompt="$(cat <<EOF
You are answering a human's read-only inspection question.

Repository: ${REPO}
${SUBJECT_CONTEXT}

Complete conversation in chronological order:
${CONVERSATION}

Current human question:
${QUESTION}

Instructions:
- Work in this checkout: ${worktree}
- Treat the checkout and all pull requests as read-only.
- Do not commit, push, edit the pull request, edit issue labels, close issues, create issues, or create pull requests.
- You may use read-only git and GitHub CLI commands to inspect current files, history, issues, and one or more pull requests.
- You may create temporary investigation files under ${worktree}/.agent-inspect-scratch if useful.
- Inspect the relevant repository state and answer the human's question directly.
- If evidence is uncertain, say what you checked and what remains unknown.
- Keep the answer concise and include relevant file paths when useful.
- Write only the final answer to this file: ${answer_file}
EOF
)"

set +e
"$REPO_ROOT/agent/scripts/agent-opencode-exec.sh" --cd "$worktree" "$prompt" 2>&1 | tee "$log_file"
opencode_status=${PIPESTATUS[0]}
set -e

if [[ "$opencode_status" -ne 0 || ! -s "$answer_file" ]]; then
  summary="$(extract_failure_summary "$log_file" "inspect failed")"
  subject="repository inspection"
  [[ -n "$PR_NUM" ]] && subject="PR #${PR_NUM}"
  agent-gh issue comment "$COMMENT_TARGET" --repo "$REPO" --body "$(cat <<EOF
## Agent inspect failed

I could not complete the read-only inspection for ${subject}.

**Why it failed:** ${summary}

Local log: \`${log_file}\`
EOF
)"
  if [[ "$INSPECT_ISSUE_MODE" == "true" ]]; then
    agent_gh_issue_edit "$COMMENT_TARGET" --repo "$REPO" --add-label "agent-failed"
  fi
  exit 1
fi

scope_note="Inspected the current repository and requested pull requests read-only."
[[ -n "$PR_NUM" ]] && scope_note="Inspected PR #${PR_NUM} read-only."
agent-gh issue comment "$COMMENT_TARGET" --repo "$REPO" --body "$(cat <<EOF
## Agent inspect

$(cat "$answer_file")

_${scope_note} No repository or PR changes were committed or pushed._
EOF
)"

if [[ "$INSPECT_ISSUE_MODE" == "true" ]]; then
  clear_agent_failed "$COMMENT_TARGET" "$REPO"
fi

mark_comment_processed "$COMMENT_TARGET" "${COMMENT_ID:-}" "inspect"
