#!/usr/bin/env bash
# Agent-goal runner. GitHub API calls run in bash; OpenCode does local work only.
#
# Usage: ./agent/scripts/run-agent-goal.sh plan|revise|implement|fix <issue_number>
#
# Optional env:
#   REVISION_COMMENT — human feedback (revise or fix)
#   PR_NUMBER        — open PR for fix phase (optional; resolved from issue if omitted)

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
  echo "Usage: $0 plan|revise|implement|fix <issue_number>" >&2
  exit 1
fi

case "$PHASE" in
  plan|revise|implement|fix) ;;
  *)
    echo "Unknown phase: $PHASE (use plan, revise, implement, or fix)" >&2
    exit 1
    ;;
esac

cd "$REPO_ROOT"

# Run logs live outside the ephemeral Actions checkout. Planning, however,
# must write inside that checkout so OpenCode never needs to cross workspaces.
LOG_DIR="$(agent_goal_issue_run_dir "$ISSUE")"
PLAN_FILE="$LOG_DIR/plan.md"
WORKSPACE_LOG_DIR="$REPO_ROOT/machine/runs/issue-${ISSUE}"
WORKSPACE_PLAN_FILE="$WORKSPACE_LOG_DIR/plan.md"

log() { echo "{\"ts\":\"$(date -u -Iseconds)\",\"phase\":\"$PHASE\",\"issue\":$ISSUE,$1}" >> "$LOG_FILE"; }

sync_workspace_artifact() {
  local source="$1" destination="$2" destination_dir temporary

  [[ -s "$source" ]] || return 0
  destination_dir="$(dirname "$destination")"
  mkdir -p "$destination_dir"
  temporary="$(mktemp "$destination_dir/.agent-sync.XXXXXX")"
  cp "$source" "$temporary"
  mv -f "$temporary" "$destination"
}

fetch_issue_field() {
  local field="$1"
  agent-gh issue view "$ISSUE" --repo "$REPO" --json "$field" --jq ".$field"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40
}

write_agent_plan_cache() {
  local dest="$1"
  if [[ -f "$PLAN_FILE" ]]; then
    cp "$PLAN_FILE" "$dest"
    return
  fi
  local agent_user
  agent_user="$(agent_github_user)"
  agent-gh issue view "$ISSUE" --repo "$REPO" --comments --json comments \
    --jq '.comments | map(select(.author.login == "'"$agent_user"'")) | last | .body // empty' > "$dest"
}

read_human_comment_cache() {
  local dest="$1"
  local agent_user
  agent_user="$(agent_github_user)"
  agent-gh issue view "$ISSUE" --repo "$REPO" --comments --json comments \
    --jq '.comments | map(select(.author.login != "'"$agent_user"'")) | last | .body // empty' > "$dest"
}

post_plan_comment() {
  local header="$1"
  agent-gh issue comment "$ISSUE" --repo "$REPO" --body "$(cat <<EOF
${header}

$(cat "$PLAN_FILE")
EOF
)"
}

run_verification() {
  if plan_has_verify_block "$PLAN_FILE"; then
    "$REPO_ROOT/agent/scripts/verify.sh" --plan "$PLAN_FILE"
  else
    "$REPO_ROOT/agent/scripts/verify.sh"
  fi
}

commit_and_push() {
  local branch="$1" message="$2"
  local allow_no_changes="${3:-false}"

  if [[ -n "${SRC_DIR:-}" && -d "$SRC_DIR" ]]; then
    agent-git add "$SRC_DIR/"
  fi
  if [[ -n "${RESULTS_DIR:-}" && -d "$RESULTS_DIR" ]]; then
    agent-git add "$RESULTS_DIR/"
  fi
  if [[ -f README.md ]]; then
    agent-git add README.md
  fi
  if [[ -f requirements.txt ]]; then
    agent-git add requirements.txt
  fi

  check_github_file_size_limit_for_staged || return 1

  if agent-git diff --cached --quiet; then
    if [[ "$allow_no_changes" == "true" ]]; then
      echo "No new changes to commit (fix already applied)." >&2
      agent-git push -u origin "$branch"
      log '"status":"finished","note":"no new changes"'
      return 0
    fi
    echo "No changes to commit." >&2
    log '"status":"failed","error":"no changes"'
    exit 1
  fi

  agent-git commit -m "$message"
  agent-git push -u origin "$branch"
}

ensure_pr_for_branch() {
  local branch="$1" title="$2" body="$3"
  local existing_pr pr_url

  existing_pr="$(find_open_pr_for_issue "$ISSUE" "$REPO")"
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

ISSUE_TITLE="$(fetch_issue_field title)"
ISSUE_BODY="$(fetch_issue_field body)"
ISSUE_URL="$(fetch_issue_field url)"
BRANCH_SLUG="$(slugify "$ISSUE_TITLE")"
ISSUE_BRANCH="agent/issue-${ISSUE}-${BRANCH_SLUG}"
SRC_DIR="$(agent_goal_src_rel "$ISSUE")"
RESULTS_DIR="$(agent_goal_results_rel "$ISSUE")"
WORK_BRANCH=""
FIX_PR_NUM=""

GOAL_KNOWLEDGE_PROMPT="$(cat <<'EOF'

Before planning or changing code, inspect knowledge/ and use any relevant
guides, samples, papers, or reference materials for this issue.
EOF
)"

TRUTHFUL_EXECUTION_RULES="$(cat <<'EOF'

Truthful execution rules:
- Follow the issue goal and the approved plan. Do not invent, simulate, or substitute fake or placeholder data, results, citations, model outputs, or external-service responses.
- If the plan requires a specific method, data source, model, or service, do not silently switch to a different method because the original path is slow, unavailable, expensive, blocked, or difficult.
- If the approved path cannot be completed truthfully, stop and report the
  blocker clearly. Preserve legitimate partial work and state what remains
  incomplete.
EOF
)"

PLAN_PROMPT_FOOTER="$(cat <<EOF

Repository layout (per issue #${ISSUE}):
- ${SRC_DIR}/ — implementation code and tests for this issue
- knowledge/ — hand-written documentation only (not generated data outputs)
- ${RESULTS_DIR}/ — all artifacts produced by running code

For long-running or high-volume jobs, plan resumable chunks:
- Define a manifest under ${RESULTS_DIR}/manifest.json or ${RESULTS_DIR}/manifest.tsv.
- Give each chunk a stable id, deterministic input range/filter, status, output path, row count, and checksum when practical.
- Treat stale/running chunks from an interrupted job as incomplete and resume from the first chunk not marked done.
- Write chunk output to a temporary file first, then atomically rename it only after the chunk is complete.
- Use chunk files as local/checkpoint-only resumable working artifacts.
- Before final commit, combine completed chunks into as few committed output files as practical while keeping every file below the GitHub file size limit.
- Do not commit, push, or upload the per-chunk output files when consolidated result files have been created. Keep ${RESULTS_DIR}/chunks/ local/checkpoint-only unless the issue explicitly asks to publish chunk files.

Include machine-readable target directories in the plan:

<!-- agent-src-target
${SRC_DIR}/
-->

<!-- agent-results-target
${RESULTS_DIR}/
-->

Include a machine-readable verification block at the end of the plan:

<!-- agent-verify
./agent/scripts/verify.sh
-->

Add extra verification commands inside the block if needed (one per line).
For agent-goal verification: Do not run pytest against repository-level agent/tests/.
Those are workflow/template tests, not issue deliverable tests. Use issue-scoped
tests such as:
python -m pytest ${SRC_DIR}/ -q
and ./agent/scripts/verify.sh.
Do NOT run git or gh. Do NOT write code. Do NOT open a PR.
End the plan with: "Awaiting human approve before implementation."
EOF
)"

plan_answer_context() {
  if [[ -n "${REVISION_COMMENT:-}" ]]; then
    cat <<EOF

Human answer to the pending clarification:
${REVISION_COMMENT}

Use this answer when writing the plan.
EOF
  fi
}

implementation_clarification_context() {
  if [[ -n "${REVISION_COMMENT:-}" ]]; then
    cat <<EOF

Human answer to the pending implementation clarification:
${REVISION_COMMENT}

Use this answer to resume implementation. Do not ask the same clarification
again unless the answer creates a new genuinely blocking ambiguity.
EOF
  fi
}

implementation_clarification_rules() {
  local question_file="$1"
  cat <<EOF

Implementation clarification policy:
- Do not ask clarification questions when the approved plan, issue, and
  repository context are clear enough to proceed with a conservative
  implementation.
- If implementation reaches a genuinely blocking ambiguity where proceeding
  would likely produce dishonest, destructive, or materially wrong work, ask
  concise clarification questions and pause.
- To pause, write each blocking question on its own line to this local file:
  ${question_file}
- Do not use this mechanism for ordinary tradeoffs, minor naming choices, or
  issues that can be handled by a documented conservative assumption.
EOF
}

goal_output_rules() {
  cat <<EOF
Write implementation code and tests under ${SRC_DIR}/.
Write all generated outputs (reports, exports, figures, summary tables, JSON/CSV) under:
${RESULTS_DIR}/
Update the top-level README.md so it accurately reflects the current status quo of the repository after this task.
Also write or update issue-specific Markdown, such as ${SRC_DIR}/README.md, ${RESULTS_DIR}/README.md, or a report under ${RESULTS_DIR}/, so a human contributor can understand the major decisions and assumptions behind the PR without reading code. Include reviewer-relevant material choices, assumptions, limitations, data/source/model/service decisions, and non-obvious behavior. Do not document every trivial implementation detail; the human can ask /agent inspect <question> for deeper details.
Do not put machine-generated data outputs under knowledge/.
Do not write implementation files directly under src/ (use ${SRC_DIR}/).
If Python packages are needed, create or reuse the repo-local plain virtual environment at machine/venv with \`python3 -m venv machine/venv\`. Do not use --system-site-packages. Install packages for agent work into machine/venv when they make the approved work easier, more reliable, or necessary. Do not wait for the human to list package names. Never commit machine/venv or package caches, and update the root requirements.txt when committed code relies on non-standard packages.
For long-running or high-volume jobs, use a resumable chunk manifest under ${RESULTS_DIR}/.
Before doing new work, inspect the manifest and existing chunk files, then continue from the first incomplete chunk instead of restarting completed chunks.
Write each chunk to a temporary file first and atomically rename it only after completion; ignore or repair stale temporary files from interrupted runs.
Use chunk files as local/checkpoint-only resumable working artifacts.
Before final commit, combine completed chunks into as few committed output files as practical while keeping every file below the GitHub file size limit.
Do not commit, push, or upload the per-chunk output files when consolidated result files have been created. Keep ${RESULTS_DIR}/chunks/ local/checkpoint-only unless the issue explicitly asks to publish chunk files.
EOF
}

build_goal_pr_body() {
  local branch="$1" phase_label="$2" change_summary="$3" version_note="$4"
  cat <<EOF
## Goal

Closes #${ISSUE}

## What's new

${version_note}

## Summary

${change_summary}

## Agent run

- Phase: \`${phase_label}\`
- Branch: \`${branch}\`
- Source: \`${SRC_DIR}/\`
- Results: \`${RESULTS_DIR}/\`
- Local log: \`${LOG_FILE}\` (runner-local, not committed)

## Verification

- [x] \`./agent/scripts/verify.sh\` (or plan \`agent-verify\` block)
EOF
}

build_goal_post_merge_fix_pr_body() {
  local branch="$1" change_summary="$2" version_note="$3"
  cat <<EOF
## Goal

Follow-up fix for closed issue #${ISSUE}

## What's new

${version_note}

## Summary

${change_summary}

## Agent run

- Phase: \`post-merge-fix\`
- Branch: \`${branch}\`
- Source: \`${SRC_DIR}/\`
- Results: \`${RESULTS_DIR}/\`
- Local log: \`${LOG_FILE}\` (runner-local, not committed)

## Verification

- [x] \`./agent/scripts/verify.sh\` (or plan \`agent-verify\` block)
EOF
}

create_post_merge_fix_branch() {
  local run_stamp branch
  run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  branch="agent/issue-${ISSUE}-${BRANCH_SLUG}-post-merge-fix-${run_stamp}"
  printf '%s' "$branch"
}

case "$PHASE" in
  plan|revise|implement)
    WORK_BRANCH="$ISSUE_BRANCH"
    if existing_branch="$(find_branch_for_issue "$ISSUE" "$REPO" 2>/dev/null)"; then
      WORK_BRANCH="$existing_branch"
    fi
    "$REPO_ROOT/agent/scripts/agent-prepare-workspace.sh" "$ISSUE" "$PHASE" goal "$WORK_BRANCH"
    ;;
  fix)
    if [[ -z "${REVISION_COMMENT:-}" ]]; then
      echo "Fix phase requires REVISION_COMMENT (PR or issue feedback)." >&2
      exit 1
    fi
    FIX_PR_NUM="${PR_NUMBER:-}"
    if [[ -z "$FIX_PR_NUM" ]]; then
      FIX_PR_NUM="$(find_open_pr_for_issue "$ISSUE" "$REPO")"
    fi
    if [[ -n "$FIX_PR_NUM" ]]; then
      WORK_BRANCH="$(agent-gh pr view "$FIX_PR_NUM" --repo "$REPO" --json headRefName --jq .headRefName)"
    else
      WORK_BRANCH="$(create_post_merge_fix_branch)"
    fi
    "$REPO_ROOT/agent/scripts/agent-prepare-workspace.sh" "$ISSUE" fix goal "$WORK_BRANCH"
    ;;
esac

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/${RUN_ID}-${PHASE}.jsonl"
export AGENT_GOAL_LOG_FILE="$LOG_FILE"

mkdir -p "$LOG_DIR"
printf '%s\n' "$LOG_FILE" > "$LOG_DIR/latest.log"
export_agent_run_paths "$LOG_FILE" "$LOG_DIR"

log '"status":"started"'

case "$PHASE" in
  plan)
    PLAN_QUESTION_FILE="$LOG_DIR/${RUN_ID}-${PHASE}-question.txt"
    WORKSPACE_PLAN_QUESTION_FILE="$WORKSPACE_LOG_DIR/${RUN_ID}-${PHASE}-question.txt"
    mkdir -p "$WORKSPACE_LOG_DIR"
    rm -f "$PLAN_FILE" "$WORKSPACE_PLAN_FILE" \
      "$PLAN_QUESTION_FILE" "$WORKSPACE_PLAN_QUESTION_FILE"
    PROMPT="$(cat <<EOF
You are agent. Follow AGENTS.md.

Human issue #${ISSUE}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

Issue body:
${ISSUE_BODY}
${GOAL_KNOWLEDGE_PROMPT}
$(plan_answer_context)
${TRUTHFUL_EXECUTION_RULES}

Write a concise implementation plan to this exact local file path ONLY:
${WORKSPACE_PLAN_FILE}

Include numbered steps, verification commands, and branch name suggestion.
If critical details are truly required before planning, write each concise
clarifying question on its own line to this exact local file ONLY:
${WORKSPACE_PLAN_QUESTION_FILE}
Do not write a plan or code while awaiting clarification. Otherwise, make a
reasonable conservative assumption, write it in the plan, and let the human
approve, revise, or reject the plan in GitHub.
${PLAN_PROMPT_FOOTER}
EOF
)"

    "$REPO_ROOT/agent/scripts/agent-opencode-exec.sh" "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
    sync_workspace_artifact "$WORKSPACE_PLAN_FILE" "$PLAN_FILE"
    sync_workspace_artifact "$WORKSPACE_PLAN_QUESTION_FILE" "$PLAN_QUESTION_FILE"

    if [[ ! -s "$PLAN_FILE" ]]; then
      if [[ -s "$PLAN_QUESTION_FILE" ]]; then
        echo "Planning clarification needed:" | tee -a "$LOG_FILE"
        cat "$PLAN_QUESTION_FILE" | tee -a "$LOG_FILE"
        log '"status":"paused","reason":"planning clarification"'
        exit 20
      fi
      echo "Plan file missing: $PLAN_FILE" >&2
      log '"status":"failed","error":"plan file empty"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "Plan file was empty or missing."
      exit 1
    fi

    SRC_DIR="$(read_src_target_from_plan "$PLAN_FILE" "$ISSUE")"
    RESULTS_DIR="$(read_results_target_from_plan "$PLAN_FILE" "$ISSUE")"

    post_plan_comment "## Plan (agent)"
    sync_agent_run_logs "$ISSUE" "$PHASE"
    log '"status":"finished","plan_file":"'"$PLAN_FILE"'"'
    ;;

  revise)
    PLAN_CACHE="$(mktemp)"
    FEEDBACK_CACHE="$(mktemp)"
    trap 'rm -f "$PLAN_CACHE" "$FEEDBACK_CACHE"' RETURN

    write_agent_plan_cache "$PLAN_CACHE"
    PRIOR_PLAN="$(cat "$PLAN_CACHE")"
    if [[ -n "${REVISION_COMMENT:-}" ]]; then
      FEEDBACK="$REVISION_COMMENT"
    else
      read_human_comment_cache "$FEEDBACK_CACHE"
      FEEDBACK="$(cat "$FEEDBACK_CACHE")"
    fi

    if [[ -z "$FEEDBACK" ]]; then
      echo "No human revision comment found for issue #${ISSUE}" >&2
      log '"status":"failed","error":"no revision comment"'
      exit 1
    fi

    rm -f "$PLAN_FILE" "$WORKSPACE_PLAN_FILE"
    mkdir -p "$WORKSPACE_LOG_DIR"
    PROMPT="$(cat <<EOF
You are agent. Follow AGENTS.md.

Human issue #${ISSUE}: ${ISSUE_TITLE}
URL: ${ISSUE_URL}

Issue body:
${ISSUE_BODY}
${GOAL_KNOWLEDGE_PROMPT}
${TRUTHFUL_EXECUTION_RULES}

Previous plan:
${PRIOR_PLAN}

Human revision request:
${FEEDBACK}

Update the implementation plan to incorporate the human feedback.
Write the revised plan to this exact local file path ONLY:
${WORKSPACE_PLAN_FILE}

Include numbered steps, verification commands, and branch name suggestion.
Do NOT ask the human clarifying questions in chat/output. If a detail is
ambiguous, make a reasonable conservative assumption, write it in the revised
plan, and let the human approve, revise, or reject the plan in GitHub.
${PLAN_PROMPT_FOOTER}
EOF
)"

    "$REPO_ROOT/agent/scripts/agent-opencode-exec.sh" "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
    sync_workspace_artifact "$WORKSPACE_PLAN_FILE" "$PLAN_FILE"

    if [[ ! -s "$PLAN_FILE" ]]; then
      echo "Revised plan file missing: $PLAN_FILE" >&2
      log '"status":"failed","error":"revised plan file empty"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "Revised plan file was empty or missing."
      exit 1
    fi

    SRC_DIR="$(read_src_target_from_plan "$PLAN_FILE" "$ISSUE")"
    RESULTS_DIR="$(read_results_target_from_plan "$PLAN_FILE" "$ISSUE")"

    post_plan_comment "## Revised plan (agent)"
    sync_agent_run_logs "$ISSUE" "$PHASE"
    log '"status":"finished","plan_file":"'"$PLAN_FILE"'","revision":true'
    ;;

  implement)
    BRANCH="${WORK_BRANCH:-$ISSUE_BRANCH}"

    PLAN_CACHE="$(mktemp)"
    IMPLEMENT_QUESTION_FILE="$LOG_DIR/${RUN_ID}-${PHASE}-question.txt"
    trap 'rm -f "$PLAN_CACHE"' RETURN
    write_agent_plan_cache "$PLAN_CACHE"
    cp "$PLAN_CACHE" "$PLAN_FILE"
    PLAN_TEXT="$(cat "$PLAN_CACHE")"
    SRC_DIR="$(read_src_target_from_plan "$PLAN_FILE" "$ISSUE")"
    RESULTS_DIR="$(read_results_target_from_plan "$PLAN_FILE" "$ISSUE")"
    mkdir -p "$SRC_DIR" "$RESULTS_DIR"
    rm -f "$IMPLEMENT_QUESTION_FILE"

    PROMPT="$(cat <<EOF
You are agent. Follow AGENTS.md.

Issue #${ISSUE}: ${ISSUE_TITLE}
${ISSUE_BODY}

Approved plan:
${PLAN_TEXT}
$(implementation_clarification_context)
${GOAL_KNOWLEDGE_PROMPT}
${TRUTHFUL_EXECUTION_RULES}

$(goal_output_rules)
$(implementation_clarification_rules "$IMPLEMENT_QUESTION_FILE")

Implement the plan in this working tree on branch ${BRANCH}.
Run verification commands from the plan before finishing.
Do NOT run git commit, git push, or gh pr create — the wrapper script handles that.
EOF
)"

    if ! run_opencode_with_longrun_progress "$ISSUE" "$REPO" "$PHASE" "$BRANCH" goal "$ISSUE_TITLE" "$PROMPT"; then
      if [[ -s "$IMPLEMENT_QUESTION_FILE" ]]; then
        echo "Implementation clarification needed:" | tee -a "$LOG_FILE"
        cat "$IMPLEMENT_QUESTION_FILE" | tee -a "$LOG_FILE"
        log '"status":"paused","reason":"implementation clarification"'
        exit 20
      fi
      log '"status":"failed","error":"OpenCode implement failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "OpenCode implementation phase failed."
      exit 1
    fi

    if [[ -s "$IMPLEMENT_QUESTION_FILE" ]]; then
      echo "Implementation clarification needed:" | tee -a "$LOG_FILE"
      cat "$IMPLEMENT_QUESTION_FILE" | tee -a "$LOG_FILE"
      log '"status":"paused","reason":"implementation clarification"'
      exit 20
    fi

    VERIFY_EXTRA="$(mktemp)"
    trap 'rm -f "$PLAN_CACHE" "$VERIFY_EXTRA"' RETURN
    if ! run_verification 2>&1 | tee -a "$LOG_FILE" | tee "$VERIFY_EXTRA"; then
      log '"status":"failed","error":"verification failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "$(cat "$VERIFY_EXTRA")"
      exit 1
    fi

    commit_and_push "$BRANCH" "agent: implement issue #${ISSUE}

${ISSUE_TITLE}"

    CHANGE_SUMMARY="$(build_pr_change_summary)"
    VERSION_NOTE="$(build_pr_functional_summary)"
    PR_BODY="$(build_goal_pr_body "$BRANCH" "implement" "$CHANGE_SUMMARY" "$VERSION_NOTE")"
    PR_URL="$(ensure_pr_for_branch "$BRANCH" "agent: ${ISSUE_TITLE} (issue #${ISSUE})" "$PR_BODY")"
    agent-gh issue comment "$ISSUE" --repo "$REPO" --body "$(cat <<EOF
Implemented in ${PR_URL}

**What changed:**
${VERSION_NOTE}

**Changed files:**
${CHANGE_SUMMARY}
EOF
)"

    sync_agent_run_logs "$ISSUE" "$PHASE"
    clear_agent_checkpoint "$ISSUE"
    log '"status":"finished","branch":"'"$BRANCH"'","pr":"'"$PR_URL"'"'
    ;;

  fix)
    FEEDBACK="${REVISION_COMMENT:-}"
    PR_NUM="${FIX_PR_NUM:-${PR_NUMBER:-}}"
    if [[ -z "$PR_NUM" ]]; then
      PR_NUM="$(find_open_pr_for_issue "$ISSUE" "$REPO" || true)"
    fi
    POST_MERGE_FIX=false
    if [[ -n "$PR_NUM" ]]; then
      BRANCH="${WORK_BRANCH:-$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq .headRefName)}"
      PR_URL="$(agent-gh pr view "$PR_NUM" --repo "$REPO" --json url --jq .url)"
    else
      POST_MERGE_FIX=true
      BRANCH="${WORK_BRANCH:-$(create_post_merge_fix_branch)}"
      PR_URL="No open PR exists; this fix will create a new draft PR from main."
    fi
    CONTEXT_PR_NUM="$PR_NUM"
    if [[ -z "$CONTEXT_PR_NUM" ]]; then
      CONTEXT_PR_NUM="$(find_latest_pr_for_issue "$ISSUE" "$REPO" || true)"
    fi
    FIX_CONVERSATION_CONTEXT="$(build_fix_conversation_context "$ISSUE" "$REPO" "$CONTEXT_PR_NUM")"
    FIX_BASE_REF="$(agent-git rev-parse HEAD)"
    POST_MERGE_FIX_RULES=""
    if [[ "$POST_MERGE_FIX" == true ]]; then
      POST_MERGE_FIX_RULES="$(cat <<EOF

Post-merge fix rules:
- The previous pull request for this issue has already been merged, so the
  current branch content from main is the source of truth.
- Treat the approved plan below as historical context only. Do not replay it or
  restore old implementation details from it.
- Preserve all behavior currently present on main unless the human feedback
  explicitly asks to change that behavior.
EOF
)"
    fi

    PLAN_CACHE="$(mktemp)"
    trap 'rm -f "$PLAN_CACHE"' RETURN
    write_agent_plan_cache "$PLAN_CACHE"
    cp "$PLAN_CACHE" "$PLAN_FILE"
    PLAN_TEXT="$(cat "$PLAN_CACHE")"
    SRC_DIR="$(read_src_target_from_plan "$PLAN_FILE" "$ISSUE")"
    RESULTS_DIR="$(read_results_target_from_plan "$PLAN_FILE" "$ISSUE")"

    PROMPT="$(cat <<EOF
You are agent. Follow AGENTS.md.

Issue #${ISSUE}: ${ISSUE_TITLE}
Pull request: ${PR_URL}
${POST_MERGE_FIX_RULES}

Approved plan:
${PLAN_TEXT}

Complete source issue and pull request conversation context:
${FIX_CONVERSATION_CONTEXT}

Human review feedback to address:
${FEEDBACK}
${GOAL_KNOWLEDGE_PROMPT}
${TRUTHFUL_EXECUTION_RULES}

$(goal_output_rules)

Apply the requested changes on branch ${BRANCH}.
If no open PR exists because the prior PR was already merged, create an
incremental patch against main in the same issue-scoped directories
(${SRC_DIR}/ and ${RESULTS_DIR}/). Preserve existing completed work unless the
human feedback explicitly requires changing it.
Run verification commands from the plan before finishing.
Do NOT run git commit, git push, or gh — the wrapper script handles that.
EOF
)"

    if ! run_opencode_with_longrun_progress "$ISSUE" "$REPO" "$PHASE" "$BRANCH" goal "$ISSUE_TITLE" "$PROMPT"; then
      log '"status":"failed","error":"OpenCode fix failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "OpenCode fix phase failed."
      exit 1
    fi

    VERIFY_EXTRA="$(mktemp)"
    trap 'rm -f "$PLAN_CACHE" "$VERIFY_EXTRA"' RETURN
    if ! run_verification 2>&1 | tee -a "$LOG_FILE" | tee "$VERIFY_EXTRA"; then
      log '"status":"failed","error":"verification failed"'
      record_phase_failure "$ISSUE" "$LOG_FILE" "$(cat "$VERIFY_EXTRA")"
      exit 1
    fi

    commit_and_push "$BRANCH" "agent: address review for issue #${ISSUE}

${FEEDBACK}" true

    CHANGE_SUMMARY="$(build_pr_change_summary "$FIX_BASE_REF")"
    VERSION_NOTE="$(build_pr_functional_summary "$FIX_BASE_REF")"
    if [[ "$POST_MERGE_FIX" == "true" ]]; then
      PR_BODY="$(build_goal_post_merge_fix_pr_body "$BRANCH" "$CHANGE_SUMMARY" "$VERSION_NOTE")"
      existing_pr="$(find_open_pr_for_issue "$ISSUE" "$REPO" || true)"
      if [[ -n "$existing_pr" ]]; then
        PR_URL="$(agent-gh pr view "$existing_pr" --repo "$REPO" --json url --jq .url)"
        agent-gh pr edit "$existing_pr" --repo "$REPO" \
          --title "agent: follow-up fix for issue #${ISSUE}" \
          --body "$PR_BODY" 2>/dev/null || true
      else
        PR_URL="$(agent-gh pr create --repo "$REPO" --draft --base main --head "$BRANCH" \
          --title "agent: follow-up fix for issue #${ISSUE}" \
          --body "$PR_BODY")"
      fi
      agent_gh_issue_edit "$ISSUE" --repo "$REPO" --add-label "agent-pr-open"
      agent-gh issue comment "$ISSUE" --repo "$REPO" --body "$(cat <<EOF
Opened follow-up fix PR: ${PR_URL}

**What changed:**
${VERSION_NOTE}

**Changed files:**
${CHANGE_SUMMARY}
EOF
)"
    else
      PR_BODY="$(build_goal_pr_body "$BRANCH" "fix" \
        "$(build_pr_change_summary)" \
        "$(build_pr_functional_summary)")"
      agent-gh pr edit "$PR_NUM" --repo "$REPO" --body "$PR_BODY" 2>/dev/null || true

      agent-gh pr comment "$PR_NUM" --repo "$REPO" --body "$(cat <<EOF
## Agent fix (agent)

Addressed review feedback and pushed to \`${BRANCH}\`.

**What changed:**
${VERSION_NOTE}

**Changed files:**
${CHANGE_SUMMARY}

Local log: \`${LOG_FILE}\`
EOF
)"
      agent-gh issue comment "$ISSUE" --repo "$REPO" --body "$(cat <<EOF
Updated ${PR_URL} per review feedback.

**What changed:**
${VERSION_NOTE}

**Changed files:**
${CHANGE_SUMMARY}
EOF
)"
    fi

    sync_agent_run_logs "$ISSUE" "$PHASE"
    clear_agent_checkpoint "$ISSUE"
    log '"status":"finished","branch":"'"$BRANCH"'","pr":"'"$PR_URL"'","fix":true'
    ;;

  *)
    echo "Unknown phase: $PHASE (use plan, revise, implement, or fix)" >&2
    exit 1
    ;;
esac
