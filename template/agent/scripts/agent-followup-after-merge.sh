#!/usr/bin/env bash
# Optionally create one follow-up agent-goal issue after a human merges an agent PR.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

PR_NUM="${1:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"

if [[ -z "$PR_NUM" ]]; then
  echo "Usage: $0 <pr_number>" >&2
  exit 1
fi

cd "$REPO_ROOT"

pr_meta="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json state,mergedAt,baseRefName,headRefName,title,url \
  --jq '[.state, (.mergedAt // ""), .baseRefName, .headRefName, .title, .url] | @tsv')"
IFS=$'\t' read -r pr_state pr_merged_at base_ref head_ref pr_title pr_url <<< "$pr_meta"

if [[ "$pr_state" != "MERGED" || -z "$pr_merged_at" || "$base_ref" != "main" ]]; then
  echo "PR #${PR_NUM} was not merged into main; no follow-up check needed."
  exit 0
fi

issue="$(resolve_issue_from_pr "$PR_NUM" "$REPO" 2>/dev/null || true)"
if [[ -z "$issue" ]]; then
  echo "PR #${PR_NUM} does not use an agent goal branch; no follow-up check needed."
  exit 0
fi

issue_state="$(agent-gh issue view "$issue" --repo "$REPO" --json state --jq .state)"
if [[ "$issue_state" != "CLOSED" ]]; then
  echo "Issue #${issue} is not CLOSED after merge; no follow-up check needed."
  exit 0
fi

run_dir="$(agent_goal_issue_run_dir "$issue")"
request_file="$run_dir/followup-after-merge.tsv"
mkdir -p "$run_dir"
rm -f "$request_file"

issue_title="$(agent-gh issue view "$issue" --repo "$REPO" --json title --jq .title)"
issue_body="$(agent-gh issue view "$issue" --repo "$REPO" --json body --jq '.body // ""')"
issue_comments="$(agent-gh issue view "$issue" --repo "$REPO" --comments --json comments \
  --jq '.comments | map(select(.author.login != "'"$(agent_github_user)"'")) | map("Comment by \(.author.login):\n\(.body)") | join("\n\n---\n\n")')"
pr_body="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body // ""')"

prompt="$(cat <<EOF
You are agent. Decide whether to request one follow-up GitHub issue after a
human merged an agent-goal PR into main and the original issue is now closed.

Original issue #${issue}: ${issue_title}
Original issue body:
${issue_body}

Human issue comments:
${issue_comments:-_No human comments._}

Merged PR #${PR_NUM}: ${pr_title}
PR URL: ${pr_url}
PR body:
${pr_body}

Rules:
- Create a follow-up only if the merged work reveals a natural next experiment,
  scale-up, evaluation, hardening step, or bounded extension that is useful as a
  separately reviewable agent-goal task.
- Also create a follow-up if the original issue or human comments explicitly
  requested a next step that was not completed by the merged PR.
- Do not create follow-ups for broad refactors, cleanup-only work,
  documentation/knowledge tasks, or work required to make the already-merged PR
  complete.
- If a follow-up is warranted, write exactly two tab-separated fields to:
  ${request_file}
  The fields are title and body. Use a concise title. The helper will add the
  [agent-goal] prefix and source-issue boilerplate.
- If no follow-up is warranted, do not create the file.
- Do not run git, gh, or issue creation commands.
EOF
)"

"$REPO_ROOT/agent/scripts/agent-opencode-exec.sh" "$prompt"

if [[ ! -s "$request_file" ]]; then
  echo "No follow-up issue requested after merge of PR #${PR_NUM}."
  exit 0
fi

IFS=$'\t' read -r title body < "$request_file" || true
title="${title#"${title%%[![:space:]]*}"}"
title="${title%"${title##*[![:space:]]}"}"
body="${body#"${body%%[![:space:]]*}"}"
body="${body%"${body##*[![:space:]]}"}"

if [[ -z "$title" || -z "$body" ]]; then
  echo "Ignoring invalid follow-up request: ${request_file}" >&2
  exit 0
fi

followup_run_key="issue-${issue}-merged-pr-${PR_NUM}"
AGENT_FOLLOWUP_RUN_KEY="$followup_run_key" \
  "$REPO_ROOT/agent/scripts/agent-create-followup-goal.sh" "$issue" "$title" "$body"
