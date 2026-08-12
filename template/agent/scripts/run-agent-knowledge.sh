#!/usr/bin/env bash
# Agent-knowledge runner. Explore, document, and open a draft PR (no plan/approval step).
#
# Usage: ./agent/scripts/run-agent-knowledge.sh document|fix <issue_number>
#
# Optional env:
#   REVISION_COMMENT — human feedback for fix phase

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO_ROOT
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
PHASE="${1:-}"
ISSUE="${2:-}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY or repo argument is required}"

# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

if [[ -z "$PHASE" || -z "$ISSUE" ]]; then
  echo "Usage: $0 document|fix <issue_number>" >&2
  exit 1
fi

case "$PHASE" in
  document|fix) ;;
  *)
    echo "Unknown phase: $PHASE (use document or fix)" >&2
    exit 1
    ;;
esac

cd "$REPO_ROOT"

LOG_DIR="$(agent_goal_issue_run_dir "$ISSUE")"
SCRATCH_DIR="$(agent_knowledge_scratch_dir "$ISSUE")"

log() { echo "{\"ts\":\"$(date -u -Iseconds)\",\"phase\":\"$PHASE\",\"issue\":$ISSUE,\"kind\":\"knowledge\",$1}" >> "$LOG_FILE"; }

fetch_issue_field() {
  local field="$1"
  agent-gh issue view "$ISSUE" --repo "$REPO" --json "$field" --jq ".$field"
}

fetch_issue_comments_context() {
  local agent_user
  agent_user="$(agent_github_user)"
  agent-gh issue view "$ISSUE" --repo "$REPO" --comments --json comments \
    --jq '.comments
      | map(select(.author.login != "'"$agent_user"'"))
      | map("Comment by \(.author.login) at \(.createdAt):\n\(.body)")
      | join("\n\n---\n\n")'
}

slugify() {
  echo "$1" | sed 's/^\[agent-knowledge\][[:space:]]*//I' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40
}

post_knowledge_pr_comment() {
  local pr_url="$1" knowledge_dir="$2" change_summary="$3" action_label="$4" version_note="$5"

  agent-gh issue comment "$ISSUE" --repo "$REPO" --body "$(cat <<EOF
## Knowledge draft PR ready

${action_label}: ${pr_url}

Deliverables: \`${knowledge_dir}/\`

${version_note}

**Changes in this version:**
${change_summary}

Review the draft PR when ready. Comment \`/agent fix <feedback>\` on the issue or PR to request updates.
EOF
)"
}

ensure_scratch_clean() {
  if [[ -d "$SCRATCH_DIR" ]]; then
    find "$SCRATCH_DIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${SCRATCH_DIR:?}"/*
  fi
}

discard_non_knowledge_changes() {
  local knowledge_dir="$1" path

  while IFS= read -r line; do
    path="${line#???}"
    [[ "$path" == "${knowledge_dir%/}/"* ]] && continue
    [[ "$path" == "README.md" ]] && continue
    [[ "$path" == "requirements.txt" ]] && continue
    [[ "$path" == machine/* ]] && continue
    agent-git checkout -- "$path" 2>/dev/null || agent-git clean -fd -- "$path" 2>/dev/null || true
  done < <(agent-git status --porcelain --untracked-files=all)

  ensure_scratch_clean
}

validate_knowledge_deliverables() {
  local knowledge_dir="$1" issue="$2"
  local file

  if [[ ! -d "$knowledge_dir" ]]; then
    echo "Knowledge directory missing: $knowledge_dir" >&2
    log '"status":"failed","error":"knowledge dir missing"'
    record_phase_failure "$issue" "$LOG_FILE" "Knowledge directory was missing: ${knowledge_dir}/."
    exit 1
  fi

  while IFS= read -r -d '' file; do
    if [[ -s "$file" ]]; then
      return 0
    fi
  done < <(find "$knowledge_dir" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)

  echo "No non-empty knowledge deliverables under ${knowledge_dir}/" >&2
  log '"status":"failed","error":"knowledge deliverables empty"'
  record_phase_failure "$issue" "$LOG_FILE" "No non-empty files were written under ${knowledge_dir}/."
  exit 1
}

commit_knowledge_only() {
  local branch="$1" message="$2" knowledge_dir="$3"

  discard_non_knowledge_changes "$knowledge_dir"
  validate_knowledge_deliverables "$knowledge_dir" "$ISSUE"

  agent-git add "$knowledge_dir/"
  agent-git add README.md
  if [[ -f requirements.txt ]]; then
    agent-git add requirements.txt
  fi

  if agent-git diff --cached --quiet; then
    echo "No knowledge documentation to commit." >&2
    log '"status":"failed","error":"no knowledge changes"'
    record_phase_failure "$ISSUE" "$LOG_FILE" "No knowledge files were staged for commit."
    exit 1
  fi

  check_github_file_size_limit_for_staged || return 1

  local staged
  staged="$(agent-git diff --cached --name-only)"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ "$path" != "${knowledge_dir%/}/"* && "$path" != "README.md" && "$path" != "requirements.txt" ]]; then
      echo "Refusing to commit non-knowledge path: $path" >&2
      log '"status":"failed","error":"non-knowledge file staged"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "Refusing to commit path outside ${knowledge_dir}/: ${path}"
      exit 1
    fi
  done <<< "$staged"

  agent-git commit -m "$message"
  agent-git push -u origin "$branch"
}

build_knowledge_pr_body() {
  local branch="$1" phase_label="$2" knowledge_dir="$3" change_summary="$4" version_note="$5"
  cat <<EOF
## Knowledge documentation

Closes #${ISSUE}

## What's new

${version_note}

## Summary

${change_summary}

Deliverables under \`${knowledge_dir}/\` (agent-chosen files for this issue).

## Agent run

- Phase: \`${phase_label}\`
- Branch: \`${branch}\`
- Knowledge dir: \`${knowledge_dir}/\`
- Local log: \`${LOG_FILE}\` (runner-local, not committed)
- Scratch exploration files were removed before commit (not pushed)
EOF
}

build_knowledge_post_merge_fix_pr_body() {
  local branch="$1" knowledge_dir="$2" change_summary="$3" version_note="$4"
  cat <<EOF
## Knowledge documentation

Follow-up fix for reopened issue #${ISSUE}

## What's new

${version_note}

## Summary

${change_summary}

Deliverables under \`${knowledge_dir}/\` (agent-chosen files for this issue).

## Agent run

- Phase: \`post-merge-fix\`
- Branch: \`${branch}\`
- Knowledge dir: \`${knowledge_dir}/\`
- Local log: \`${LOG_FILE}\` (runner-local, not committed)
- Scratch exploration files were removed before commit (not pushed)
EOF
}

create_post_merge_fix_branch() {
  local run_stamp
  run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  printf 'agent/knowledge-issue-%s-%s-post-merge-fix-%s' \
    "$ISSUE" "$BRANCH_SLUG" "$run_stamp"
}

ensure_pr_for_branch() {
  local branch="$1" title="$2" body="$3"
  local existing_pr pr_url

  existing_pr="$(find_open_pr_for_knowledge_issue "$ISSUE" "$REPO")"
  if [[ -n "$existing_pr" ]]; then
    pr_url="$(agent-gh pr view "$existing_pr" --repo "$REPO" --json url --jq .url)"
    agent-gh pr edit "$existing_pr" --repo "$REPO" --body "$body" 2>/dev/null || true
    printf '%s' "$pr_url"
    return 0
  fi

  pr_url="$(agent-gh pr create --repo "$REPO" --draft --base main --head "$branch" \
    --title "$title" \
    --body "$body")"
  agent_gh_issue_edit "$ISSUE" --repo "$REPO" --add-label "agent-pr-open"
  printf '%s' "$pr_url"
}

KNOWLEDGE_DOC_STYLE="$(cat <<'EOF'

Final knowledge deliverables style:
- Choose whatever files best help future agents (markdown, code samples, papers, links
  in markdown, etc.). There is no required file-type checklist.
- Keep written knowledge deliverables brief. A README.md is often useful but not mandatory if another
  file format fits better.
- Common patterns when useful: a short README plus a minimal runnable sample for an
  access pattern to a service, API, database, model, website, or dataset; or a
  saved imported document plus a short summary, extraction notes, or highlighted section.
- Omit verification/process details, scratch-script narratives, command transcripts,
  and detailed investigation history from committed deliverables.
EOF
)"

TRUTHFUL_EXECUTION_RULES="$(cat <<'EOF'

Truthful execution rules:
- Follow the issue goal. Do not invent, simulate, or substitute fake or placeholder data, results, citations, model outputs, or external-service responses.
- If the issue requires a specific method, data source, model, or service, do not silently switch to a different method because the original path is slow, unavailable, expensive, blocked, or difficult.
- If the requested knowledge cannot be documented truthfully, stop and report
  the blocker clearly. Preserve legitimate partial work and state what remains
  incomplete.
EOF
)"

build_knowledge_work_prompt() {
  local branch="$1" extra_context="${2:-}"
  cat <<EOF
You are agent. Follow AGENTS.md (Agent knowledge workflow).

Issue #${ISSUE}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

Issue body:
${ISSUE_BODY}

Human issue comments:
${ISSUE_COMMENTS_CONTEXT:-_No human comments._}
${extra_context}

Work directly on branch ${branch}. There is no plan or approval step — explore,
write deliverables, and finish when the knowledge under ${KNOWLEDGE_DIR}/ is ready
for the wrapper to commit.

This job runs on a self-hosted runner with repo-scoped filesystem access and
host network access. Connect to remote data services directly when needed.
Repo-local credentials and logs (never commit these paths or their contents):
- ClickHouse: ${AGENT_CLICKHOUSE_CREDENTIALS}
- GitHub agent: ${AGENT_GITHUB_CREDENTIALS}
- Run log: ${LOG_FILE}
Write temporary scripts ONLY under the local scratch directory:
${SCRATCH_DIR}/

If Python packages are needed, create or reuse the repo-local plain virtual
environment at machine/venv with \`python3 -m venv machine/venv\`. Do not use --system-site-packages.
Install packages for agent work into machine/venv when they make the approved
work easier, more reliable, or necessary. Do not wait for the human to list package names.
Never commit machine/venv or package caches, and update the root requirements.txt
when committed knowledge samples rely on non-standard packages.

If the issue body or human comments link to a GitHub attachment such as
\`https://github.com/user-attachments/...\`, download it with:
\`agent-download-attachment "<url>" "${SCRATCH_DIR}/<filename>"\`
This helper authenticates as agent by parsing \`access_token\` from
\`${AGENT_GITHUB_CREDENTIALS}\`. Do not pass the raw JSON credentials file to
\`curl -H Authorization\`. If the attachment is a paper needed for future agents,
copy the final PDF from scratch into \`${KNOWLEDGE_DIR}/\` and summarize it.

${TRUTHFUL_EXECUTION_RULES}

Write final knowledge deliverables under:
${KNOWLEDGE_DIR}/

Update the top-level README.md so it accurately reflects the current status quo of the repository after this knowledge task.

Choose the files that best capture reusable knowledge for this issue. Examples when
they fit: a brief README, a minimal access-pattern sample for a service, API,
database, model, website, or dataset; a saved imported document plus summary or
extraction notes; or other artifacts future agents should reference.

${KNOWLEDGE_DOC_STYLE}

Before finishing:
1. Delete ALL files under ${SCRATCH_DIR}/
2. Ensure only committed deliverables live under ${KNOWLEDGE_DIR}/
3. Do NOT run git commit, git push, or gh — the wrapper script handles that
EOF
}

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/${RUN_ID}-knowledge-${PHASE}.jsonl"
export AGENT_GOAL_LOG_FILE="$LOG_FILE"

mkdir -p "$LOG_DIR" "$SCRATCH_DIR"
printf '%s\n' "$LOG_FILE" > "$LOG_DIR/latest.log"
export_agent_run_paths "$LOG_FILE" "$LOG_DIR"
log '"status":"started"'

ISSUE_TITLE="$(fetch_issue_field title)"
ISSUE_BODY="$(fetch_issue_field body)"
ISSUE_URL="$(fetch_issue_field url)"
ISSUE_COMMENTS_CONTEXT="$(fetch_issue_comments_context)"
BRANCH_SLUG="$(slugify "$ISSUE_TITLE")"
ISSUE_BRANCH="agent/knowledge-issue-${ISSUE}-${BRANCH_SLUG}"
KNOWLEDGE_DIR="$(agent_knowledge_issue_dir_rel "$ISSUE")"
WORK_BRANCH=""
FIX_PR_NUM=""

case "$PHASE" in
  document)
    WORK_BRANCH="$ISSUE_BRANCH"
    if existing_branch="$(find_branch_for_knowledge_issue "$ISSUE" "$REPO" 2>/dev/null)"; then
      WORK_BRANCH="$existing_branch"
    fi
    "$REPO_ROOT/agent/scripts/agent-prepare-workspace.sh" "$ISSUE" "$PHASE" knowledge "$WORK_BRANCH"
    ;;
  fix)
    if [[ -z "${REVISION_COMMENT:-}" ]]; then
      echo "Fix phase requires REVISION_COMMENT (PR or issue feedback)." >&2
      exit 1
    fi
    FIX_PR_NUM="${PR_NUMBER:-}"
    if [[ -z "$FIX_PR_NUM" ]]; then
      FIX_PR_NUM="$(find_open_pr_for_knowledge_issue "$ISSUE" "$REPO" || true)"
    fi
    if [[ -n "$FIX_PR_NUM" ]]; then
      WORK_BRANCH="$(agent-gh pr view "$FIX_PR_NUM" --repo "$REPO" --json headRefName --jq .headRefName)"
    else
      WORK_BRANCH="$(create_post_merge_fix_branch)"
    fi
    "$REPO_ROOT/agent/scripts/agent-prepare-workspace.sh" "$ISSUE" fix knowledge "$WORK_BRANCH"
    ;;
esac
mkdir -p "$KNOWLEDGE_DIR"

case "$PHASE" in
  document)
    BRANCH="${WORK_BRANCH:-$ISSUE_BRANCH}"
    PROMPT="$(build_knowledge_work_prompt "$BRANCH")"

    if ! run_opencode_with_longrun_progress "$ISSUE" "$REPO" "$PHASE" "$BRANCH" knowledge "$ISSUE_TITLE" "$PROMPT"; then
      log '"status":"failed","error":"OpenCode document failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "OpenCode knowledge documentation phase failed."
      exit 1
    fi

    commit_knowledge_only "$BRANCH" "agent: document knowledge for issue #${ISSUE}

${ISSUE_TITLE}" "$KNOWLEDGE_DIR"

    CHANGE_SUMMARY="$(build_pr_change_summary)"
    VERSION_NOTE="$(build_pr_functional_summary)"
    PR_BODY="$(build_knowledge_pr_body "$BRANCH" "document" "$KNOWLEDGE_DIR" "$CHANGE_SUMMARY" "$VERSION_NOTE")"
    PR_URL="$(ensure_pr_for_branch "$BRANCH" "agent: ${ISSUE_TITLE} (issue #${ISSUE})" "$PR_BODY")"
    post_knowledge_pr_comment "$PR_URL" "$KNOWLEDGE_DIR" "$CHANGE_SUMMARY" "Opened draft PR" "$VERSION_NOTE"

    sync_agent_run_logs "$ISSUE" "$PHASE"
    clear_agent_checkpoint "$ISSUE"
    log '"status":"finished","branch":"'"$BRANCH"'","pr":"'"$PR_URL"'","knowledge_dir":"'"$KNOWLEDGE_DIR"'"'
    ;;

  fix)
    FEEDBACK="${REVISION_COMMENT:-}"
    PR_NUM="${FIX_PR_NUM:-${PR_NUMBER:-}}"
    BRANCH="${WORK_BRANCH:-}"
    POST_MERGE_FIX=false
    if [[ -n "$PR_NUM" ]]; then
      PR_URL="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json url --jq .url)"
    else
      POST_MERGE_FIX=true
      PR_URL="No open PR exists; this fix will create a new draft PR from main."
    fi
    CONTEXT_PR_NUM="$PR_NUM"
    if [[ -z "$CONTEXT_PR_NUM" ]]; then
      CONTEXT_PR_NUM="$(find_latest_pr_for_knowledge_issue "$ISSUE" "$REPO" || true)"
    fi
    FIX_CONVERSATION_CONTEXT="$(build_fix_conversation_context "$ISSUE" "$REPO" "$CONTEXT_PR_NUM")"
    FIX_BASE_REF="$(agent-git rev-parse HEAD)"
    POST_MERGE_FIX_RULES=""
    if [[ "$POST_MERGE_FIX" == true ]]; then
      POST_MERGE_FIX_RULES="$(cat <<EOF

Post-merge fix rules:
- The previous pull request for this issue has already been merged, so the
  current branch content from main is the source of truth.
- Apply only the requested incremental change and preserve the existing
  knowledge deliverables unless the feedback explicitly changes them.
EOF
)"
    fi

    PROMPT="$(build_knowledge_work_prompt "$BRANCH" "$(cat <<EOF

Pull request: ${PR_URL}
${POST_MERGE_FIX_RULES}

Complete source issue and pull request conversation context:
${FIX_CONVERSATION_CONTEXT}

Human review feedback to address:
${FEEDBACK}
EOF
)")"

    if ! run_opencode_with_longrun_progress "$ISSUE" "$REPO" "$PHASE" "$BRANCH" knowledge "$ISSUE_TITLE" "$PROMPT"; then
      log '"status":"failed","error":"OpenCode knowledge fix failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "OpenCode knowledge fix phase failed."
      exit 1
    fi

    commit_knowledge_only "$BRANCH" "agent: address knowledge review for issue #${ISSUE}

${FEEDBACK}" "$KNOWLEDGE_DIR"

    CHANGE_SUMMARY="$(build_pr_change_summary "$FIX_BASE_REF")"
    VERSION_NOTE="$(build_pr_functional_summary "$FIX_BASE_REF")"
    if [[ "$POST_MERGE_FIX" == true ]]; then
      PR_BODY="$(build_knowledge_post_merge_fix_pr_body "$BRANCH" "$KNOWLEDGE_DIR" "$CHANGE_SUMMARY" "$VERSION_NOTE")"
      PR_URL="$(agent-gh pr create --repo "$REPO" --draft --base main --head "$BRANCH" \
        --title "agent: follow-up knowledge fix for issue #${ISSUE}" \
        --body "$PR_BODY")"
      agent_gh_issue_edit "$ISSUE" --repo "$REPO" --add-label "agent-pr-open"
      ACTION_LABEL="Opened follow-up draft PR"
    else
      PR_BODY="$(build_knowledge_pr_body "$BRANCH" "fix" "$KNOWLEDGE_DIR" "$CHANGE_SUMMARY" "$VERSION_NOTE")"
      agent-gh pr edit "$PR_NUM" --repo "$REPO" --body "$PR_BODY" 2>/dev/null || true

      agent-gh pr comment "$PR_NUM" --repo "$REPO" --body "$(cat <<EOF
## Agent fix (agent)

Addressed review feedback and pushed to \`${BRANCH}\`.

${VERSION_NOTE}

**Changes in this version:**
${CHANGE_SUMMARY}

Local log: \`${LOG_FILE}\`
EOF
)"
      ACTION_LABEL="Updated draft PR"
    fi
    post_knowledge_pr_comment "$PR_URL" "$KNOWLEDGE_DIR" "$CHANGE_SUMMARY" "$ACTION_LABEL" "$VERSION_NOTE"

    sync_agent_run_logs "$ISSUE" "$PHASE"
    clear_agent_checkpoint "$ISSUE"
    log '"status":"finished","branch":"'"$BRANCH"'","pr":"'"$PR_URL"'","fix":true'
    ;;

  *)
    echo "Unknown phase: $PHASE (use document or fix)" >&2
    exit 1
    ;;
esac
