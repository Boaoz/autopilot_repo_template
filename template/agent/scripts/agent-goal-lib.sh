#!/usr/bin/env bash
# Shared helpers for agent-goal orchestration (source, do not execute).

agent_repo_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s' "$REPO_ROOT"
    return
  fi
  if [[ -n "${AGENT_REPO_ROOT:-}" ]]; then
    printf '%s' "$AGENT_REPO_ROOT"
    return
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

agent_machine_dir() {
  if [[ -n "${AGENT_MACHINE_DIR:-}" ]]; then
    printf '%s' "$AGENT_MACHINE_DIR"
    return
  fi
  echo "$(agent_repo_root)/machine"
}

agent_goal_state_dir() {
  echo "$(agent_machine_dir)/state"
}

agent_github_user() {
  if [[ -n "${AGENT_GITHUB_USERNAME:-}" ]]; then
    printf '%s' "$AGENT_GITHUB_USERNAME"
    return 0
  fi

  local cred_file="${AGENT_GITHUB_CREDENTIALS:-$(agent_repo_root)/credentials/github_agent.txt}"
  if [[ -f "$cred_file" ]]; then
    python3 - "$cred_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["username"])
PY
    return 0
  fi

  printf '%s' "agent"
}

comment_author_is_agent() {
  local author="${1:-}"
  [[ -n "$author" && "$author" == "$(agent_github_user)" ]]
}

agent_runs_dir() {
  if [[ -n "${AGENT_RUNS_DIR:-}" ]]; then
    printf '%s' "$AGENT_RUNS_DIR"
    return
  fi
  echo "$(agent_machine_dir)/runs"
}

agent_goal_issue_run_dir() {
  local issue="$1"
  echo "$(agent_runs_dir)/issue-${issue}"
}

agent_checkpoint_dir() {
  local issue="$1"
  echo "$(agent_goal_issue_run_dir "$issue")/checkpoint"
}

agent_goal_results_dir() {
  local issue="$1"
  echo "$(agent_repo_root)/res/issue-${issue}"
}

agent_goal_results_rel() {
  local issue="$1"
  echo "res/issue-${issue}"
}

agent_goal_src_rel() {
  local issue="$1"
  echo "src/issue-${issue}"
}

agent_knowledge_issue_dir_rel() {
  local issue="$1"
  echo "knowledge/issue-${issue}"
}

agent_github_max_file_bytes() {
  printf '%s' "${AGENT_GITHUB_MAX_FILE_BYTES:-100000000}"
}

agent_file_size_bytes() {
  local path="$1"
  if stat -c '%s' "$path" >/dev/null 2>&1; then
    stat -c '%s' "$path"
  else
    wc -c < "$path" | tr -d '[:space:]'
  fi
}

format_bytes_for_agent() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN {
    if (bytes >= 1073741824) {
      printf "%.2f GB", bytes / 1073741824
    } else if (bytes >= 1048576) {
      printf "%.2f MB", bytes / 1048576
    } else if (bytes >= 1024) {
      printf "%.2f KB", bytes / 1024
    } else {
      printf "%d bytes", bytes
    }
  }'
}

agent_check_file_size_limit() {
  local _source="${1:-worktree}"
  local max_bytes path size limit_text found=false
  max_bytes="$(agent_github_max_file_bytes)"
  limit_text="$(format_bytes_for_agent "$max_bytes")"

  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] || continue
    size="$(agent_file_size_bytes "$path")"
    if (( size > max_bytes )); then
      found=true
      printf 'File exceeds GitHub upload limit (%s > %s): %s\n' \
        "$(format_bytes_for_agent "$size")" "$limit_text" "$path" >&2
    fi
  done

  if [[ "$found" == "true" ]]; then
    printf 'Split, compress, summarize, or omit oversized generated outputs before commit. Every file pushed to GitHub must be <= %s.\n' "$limit_text" >&2
    return 1
  fi

  return 0
}

check_github_file_size_limit_for_repo() {
  local repo_root="${1:-$(agent_repo_root)}"
  agent_check_file_size_limit "repo" < <(
    cd "$repo_root"
    git ls-files -z --cached --others --exclude-standard | tr '\0' '\n'
  )
}

check_github_file_size_limit_for_staged() {
  agent_check_file_size_limit "staged" < <(agent-git diff --cached --name-only --diff-filter=ACMR)
}

export_agent_run_paths() {
  local log_file="$1" run_dir="$2"
  if [[ -n "${GITHUB_ENV:-}" && -f "$GITHUB_ENV" ]]; then
    {
      echo "AGENT_GOAL_LOG_FILE=$log_file"
      echo "AGENT_RUN_DIR=$run_dir"
    } >> "$GITHUB_ENV"
  fi
}

sync_agent_run_logs() {
  local issue="$1" phase="$2"
  local run_dir="${3:-$(agent_goal_issue_run_dir "$issue")}"
  local cleanup_scratch="${4:-true}"

  [[ -d "$run_dir" ]] || return 0

  if [[ "$cleanup_scratch" == "true" && -d "${run_dir}/scratch" ]]; then
    find "${run_dir}/scratch" -mindepth 1 -delete 2>/dev/null || true
  fi

  printf 'Agent run logs for issue #%s phase %s are local only: %s\n' "$issue" "$phase" "$run_dir" >&2
}

normalize_comment_body() {
  local body="$1"
  body="${body,,}"
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  printf '%s' "$body"
}

command_has_boundary() {
  local body="$1" command="$2" rest
  [[ "$body" == "$command"* ]] || return 1
  rest="${body:${#command}}"
  [[ -z "$rest" || "$rest" == [[:space:]]* || "$rest" == [:,\;\?\!.-]* ]]
}

is_approve_comment() {
  local body
  body="$(normalize_comment_body "$1")"
  case "$body" in
    /agent\ approve) return 0 ;;
    *) return 1 ;;
  esac
}

is_retry_comment() {
  local body
  body="$(normalize_comment_body "$1")"
  command_has_boundary "$body" "/agent retry"
}

is_revise_comment() {
  local body feedback
  body="$(normalize_comment_body "$1")"
  command_has_boundary "$body" "/agent revise" || return 1
  feedback="$(strip_revise_feedback "$1")"
  [[ -n "$feedback" ]]
}

is_fix_comment() {
  local body feedback
  body="$(normalize_comment_body "$1")"
  command_has_boundary "$body" "/agent fix" || return 1
  feedback="$(strip_fix_feedback "$1")"
  [[ -n "$feedback" ]]
}

is_inspect_comment() {
  local body question
  body="$(normalize_comment_body "$1")"
  command_has_boundary "$body" "/agent inspect" || return 1
  question="$(strip_inspect_question "$1")"
  [[ -n "$question" ]]
}

is_answer_comment() {
  local body
  body="$(normalize_comment_body "$1")"
  command_has_boundary "$body" "/agent answer"
}

is_cancel_comment() {
  local body
  body="$(normalize_comment_body "$1")"
  case "$body" in
    /agent\ cancel) return 0 ;;
    *) return 1 ;;
  esac
}

is_agent_slash_command() {
  local body
  body="$(normalize_comment_body "$1")"
  [[ "$body" == /agent* ]]
}

strip_agent_command_feedback() {
  local body="$1" command="$2"
  local cmd_len="${#command}"

  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  if [[ "${body,,}" == "${command,,}"* ]]; then
    body="${body:$cmd_len}"
    body="${body#"${body%%[!:,;\?\!.-]*}"}"
    body="${body#"${body%%[![:space:]]*}"}"
  fi
  printf '%s' "$body"
}

strip_revise_feedback() {
  strip_agent_command_feedback "$1" "/agent revise"
}

strip_fix_feedback() {
  strip_agent_command_feedback "$1" "/agent fix"
}

strip_inspect_question() {
  strip_agent_command_feedback "$1" "/agent inspect"
}

strip_answer_feedback() {
  strip_agent_command_feedback "$1" "/agent answer"
}

latest_human_fix_comment() {
  local issue="$1" repo="$2"
  local agent_user
  agent_user="$(agent_github_user)"
  agent-gh issue view "$issue" --repo "$repo" --comments --json comments \
    --jq '.comments
      | map(select(.author.login != "'"$agent_user"'" and (.body | test("(?i)/agent fix"))))
      | last
      | .body // empty' \
    | sed -E 's#^[[:space:]]*/agent[[:space:]]+fix[[:space:]]*##I'
}

has_label() {
  local issue="$1" label="$2" repo="$3"
  agent-gh issue view "$issue" --repo "$repo" --json labels \
    --jq ".labels | map(.name) | index(\"$label\") != null"
}

# gh issue edit prints the issue URL to stdout; silence side-effect label edits.
agent_gh_issue_edit() {
  agent-gh issue edit "$@" &>/dev/null || true
}

comment_already_processed() {
  local issue="$1" comment_id="$2"
  [[ -z "$comment_id" ]] && return 1

  local state_file
  state_file="$(agent_goal_state_dir)/issue-${issue}-comments.tsv"
  [[ -f "$state_file" ]] || return 1
  grep -q "^${comment_id}	" "$state_file" 2>/dev/null
}

mark_comment_processed() {
  local issue="$1" comment_id="$2" phase="$3"
  [[ -z "$comment_id" ]] && return 0

  local state_dir state_file
  state_dir="$(agent_goal_state_dir)"
  state_file="$state_dir/issue-${issue}-comments.tsv"
  mkdir -p "$state_dir"
  printf '%s\t%s\t%s\n' "$comment_id" "$phase" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$state_file"
}

mark_agent_failed() {
  local issue="$1" repo="$2" phase="$3" log_file="$4" detail="${5:-Agent phase exited with an error.}"
  local summary="${6:-}" detail_text=""

  if [[ -z "$summary" ]]; then
    detail_text="$(read_agent_failure_summary "$issue" || true)"
  fi
  if [[ -z "$summary" ]]; then
    summary="$(summarize_agent_failure_from_log "$log_file" "${detail_text:-$detail}")"
  fi
  if [[ -z "$summary" && -n "$detail_text" ]]; then
    summary="$detail_text"
  fi
  if [[ -z "$summary" ]]; then
    summary="$detail"
  fi

  agent_gh_issue_edit "$issue" --repo "$repo" --add-label "agent-failed"
  agent-gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
## Agent run failed

**Why it failed:** ${summary}

- Phase: \`${phase}\`
- Log: \`${log_file}\`

Comment \`/agent retry\` on this issue to clear the failure state and re-run the next applicable phase.
EOF
)"
}

clear_agent_failed() {
  local issue="$1" repo="$2"
  agent_gh_issue_edit "$issue" --repo "$repo" --remove-label "agent-failed"
}

mark_agent_cancelled() {
  local issue="$1" repo="$2"
  agent_gh_issue_edit "$issue" --repo "$repo" --add-label "agent-cancelled"
  agent-gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
Agent automation cancelled on this issue.

Re-open automation by removing the \`agent-cancelled\` label and commenting \`/agent retry\`, or open a new agent issue.
EOF
)"
}

clear_agent_cancelled() {
  local issue="$1" repo="$2"
  agent_gh_issue_edit "$issue" --repo "$repo" --remove-label "agent-cancelled"
}

resolve_issue_from_pr() {
  local pr="$1" repo="$2"
  agent-gh pr view "$pr" --repo "$repo" --json headRefName \
    --jq '.headRefName | capture("agent/issue-(?<n>[0-9]+)-") | .n // empty'
}

find_open_pr_for_issue() {
  local issue="$1" repo="$2"
  agent-gh pr list --repo "$repo" --state open --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("agent/issue-'"$issue"'-")) | .number' | head -1
}

find_latest_pr_for_issue() {
  local issue="$1" repo="$2"
  agent-gh pr list --repo "$repo" --state all --limit 100 --json number,headRefName,updatedAt \
    --jq '[.[] | select(.headRefName | startswith("agent/issue-'"$issue"'-"))] | sort_by(.updatedAt) | last | .number // empty'
}

build_issue_conversation_context() {
  local issue="$1" repo="$2"
  agent-gh issue view "$issue" --repo "$repo" --comments --json body,author,comments --jq '
    "Source issue opened by \(.author.login):\n\(.body // "")" +
    ((.comments // []) | map("\n\n---\n\nIssue comment by \(.author.login) at \(.createdAt):\n\(.body)") | join(""))
  '
}

read_inspect_conversation() {
  local target="$1"
  agent-gh issue view "$target" --repo "$REPO" --comments --json body,author,comments --jq '
    "Issue or pull request opened by \(.author.login):\n\(.body // "")" +
    ((.comments // []) | map("\n\n---\n\nComment by \(.author.login) at \(.createdAt):\n\(.body)") | join(""))
  '
}

build_pr_conversation_context() {
  local pr="$1" repo="$2" inline_comments
  [[ -n "$pr" ]] || return 0

  agent-gh pr view "$pr" --repo "$repo" --json body,author,comments,reviews,url,title --jq '
    "Pull request #" + "'"$pr"'" + ": \(.title)\nURL: \(.url)\nOpened by \(.author.login):\n\(.body // "")" +
    ((.comments // []) | map("\n\n---\n\nPR comment by \(.author.login) at \(.createdAt):\n\(.body)") | join("")) +
    ((.reviews // []) | map("\n\n---\n\nReview by \(.author.login) at \(.submittedAt // "unknown time") [\(.state)]:\n\(.body // "")") | join(""))
  '

  inline_comments="$(agent-gh api --paginate "repos/${repo}/pulls/${pr}/comments" --jq '
    .[] | "\n\n---\n\nInline review comment by \(.user.login) at \(.created_at) on \(.path):\(.line // .original_line // 0):\n\(.body)"
  ' 2>/dev/null || true)"
  if [[ -n "$inline_comments" ]]; then
    printf '%s\n' "$inline_comments"
  fi
}

build_fix_conversation_context() {
  local issue="$1" repo="$2" pr="${3:-}"
  printf '%s\n' "$(build_issue_conversation_context "$issue" "$repo")"
  if [[ -n "$pr" ]]; then
    printf '\n======= PULL REQUEST CONVERSATION =======\n\n'
    build_pr_conversation_context "$pr" "$repo"
  fi
}

find_branch_for_issue() {
  local issue="$1" repo="$2"
  local pr branch
  pr="$(find_open_pr_for_issue "$issue" "$repo")"
  if [[ -n "$pr" ]]; then
    branch="$(agent-gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
    printf '%s' "$branch"
    return 0
  fi
  branch="$(agent-git branch -r --list "origin/agent/issue-${issue}-*" | head -1 | sed 's#^[[:space:]]*origin/##')"
  if [[ -n "$branch" ]]; then
    printf '%s' "$branch"
    return 0
  fi
  return 1
}

latest_agent_log() {
  local issue="$1"
  local run_dir log_file
  run_dir="$(agent_goal_issue_run_dir "$issue")"
  if [[ -n "${AGENT_GOAL_LOG_FILE:-}" ]]; then
    printf '%s' "$AGENT_GOAL_LOG_FILE"
    return 0
  fi
  log_file="$(find "$run_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-)"
  if [[ -n "$log_file" ]]; then
    printf '%s' "$log_file"
    return 0
  fi
  log_file="$run_dir/latest.log"
  if [[ -f "$log_file" ]]; then
    cat "$log_file"
    return 0
  fi
  printf '%s' "unknown.jsonl"
}

plan_has_verify_block() {
  local plan_file="$1"
  [[ -f "$plan_file" ]] && grep -q 'agent-verify' "$plan_file"
}

PLAN_VERIFY_TEMPLATE='<!-- agent-verify
./agent/scripts/verify.sh
-->'

agent_knowledge_scratch_dir() {
  local issue="$1"
  echo "$(agent_goal_issue_run_dir "$issue")/scratch"
}

read_plan_block_value() {
  local plan_file="$1" block_name="$2"
  local target=""

  if [[ -f "$plan_file" ]]; then
    target="$(sed -n "/<!-- ${block_name}/,/-->/p" "$plan_file" \
      | grep -v "$block_name" | grep -v '^-->' | sed '/^[[:space:]]*$/d' | head -1)"
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"
  fi
  printf '%s' "$target"
}

read_knowledge_target_from_plan() {
  local plan_file="$1" issue="$2" slug="${3:-}"
  local target

  target="$(read_plan_block_value "$plan_file" "agent-knowledge-target")"
  if [[ -z "$target" ]]; then
    target="$(agent_knowledge_issue_dir_rel "$issue")"
  fi
  target="${target%/}"
  printf '%s' "$target"
}

read_src_target_from_plan() {
  local plan_file="$1" issue="$2"
  local target

  target="$(read_plan_block_value "$plan_file" "agent-src-target")"
  if [[ -z "$target" ]]; then
    target="$(agent_goal_src_rel "$issue")"
  fi
  target="${target%/}"
  printf '%s' "$target"
}

read_results_target_from_plan() {
  local plan_file="$1" issue="$2"
  local target

  target="$(read_plan_block_value "$plan_file" "agent-results-target")"
  if [[ -z "$target" ]]; then
    target="$(agent_goal_results_rel "$issue")"
  fi
  target="${target%/}"
  printf '%s' "$target"
}

write_agent_failure_summary() {
  local issue="$1" summary="$2"
  local detail_file
  detail_file="$(agent_goal_issue_run_dir "$issue")/last-failure.detail"
  mkdir -p "$(dirname "$detail_file")"
  printf '%s' "$summary" > "$detail_file"
}

read_agent_failure_summary() {
  local issue="$1"
  local detail_file
  detail_file="$(agent_goal_issue_run_dir "$issue")/last-failure.detail"
  if [[ -f "$detail_file" ]]; then
    cat "$detail_file"
    return 0
  fi
  return 1
}

agent_clarification_dir() {
  local issue="$1"
  echo "$(agent_goal_state_dir)/issue-${issue}-clarification"
}

write_agent_clarification_question() {
  local issue="$1" phase="$2" question="$3"
  local dir
  dir="$(agent_clarification_dir "$issue")"
  mkdir -p "$dir"
  printf '%s' "$phase" > "$dir/phase"
  printf '%s' "$question" > "$dir/question"
  rm -f "$dir/answer"
}

read_agent_clarification_phase() {
  local issue="$1" file
  file="$(agent_clarification_dir "$issue")/phase"
  [[ -f "$file" ]] && cat "$file"
}

read_agent_clarification_question() {
  local issue="$1" file
  file="$(agent_clarification_dir "$issue")/question"
  [[ -f "$file" ]] && cat "$file"
}

write_agent_clarification_answer() {
  local issue="$1" answer="$2" dir
  dir="$(agent_clarification_dir "$issue")"
  mkdir -p "$dir"
  printf '%s' "$answer" > "$dir/answer"
}

read_agent_clarification_answer() {
  local issue="$1" file
  file="$(agent_clarification_dir "$issue")/answer"
  [[ -f "$file" ]] && cat "$file"
}

clear_agent_clarification() {
  local issue="$1"
  rm -rf "$(agent_clarification_dir "$issue")"
}

extract_agent_question_from_log() {
  local log_file="${1:-}" question="" questions="" candidate=""
  [[ -f "$log_file" ]] || return 1

  is_agent_question_candidate() {
    local line="$1"
    [[ -n "$line" ]] || return 1
    [[ "$line" == *\? ]] || return 1
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '```'* | +* | '>'* | -* | '{'* | *'$?'*) return 1 ;;
      if\ * | then\ * | else\ * | elif\ * | fi\ * | for\ * | while\ * | do\ * | done\ * | case\ * | esac\ *) return 1 ;;
      set\ * | export\ * | local\ * | echo\ * | printf\ * | grep\ * | sed\ * | awk\ * | tail\ * | head\ * | cat\ *) return 1 ;;
      bash\ * | sh\ * | python\ * | git\ * | gh\ * | agent-git\ * | agent-gh\ *) return 1 ;;
      *.sh:* | *.py:* | *.yml:* | *.yaml:* | *.json:* | *.md:* | *.txt:*) return 1 ;;
    esac
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && return 1
    [[ "$line" =~ [\;\|\&][[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && return 1
    return 0
  }

  # Paused plan and implementation phases echo their question files under this marker.
  questions="$(
    awk '
      /^(Planning|Implementation) clarification needed:$/ { collecting=1; next }
      collecting && /\?$/ { print; next }
      collecting { exit }
    ' "$log_file"
  )"
  if [[ -n "$questions" ]]; then
    while IFS= read -r candidate; do
      if ! is_agent_question_candidate "$candidate"; then
        questions=""
        break
      fi
    done <<< "$questions"
  fi
  if [[ -n "$questions" ]]; then
    printf '%s' "$questions"
    return 0
  fi

  question="$(
    grep -E '\?$' "$log_file" 2>/dev/null \
      | grep -Ev '^\+|^/bin/sh|^exec|^user|^OpenCode|^tokens used|^\{' \
      | tail -n 1 \
      | sed -E 's#^([^[:space:]:]+/)*[^[:space:]:]+:[0-9]+:##; s/^[[:space:]]*//; s/[[:space:]]*$//'
  )"
  if ! is_agent_question_candidate "$question"; then
    question=""
  fi
  if [[ -z "$question" ]]; then
    question="$(
      tail -n 80 "$log_file" \
        | awk 'NF { last=$0 } END { print last }' \
        | sed -E 's#^([^[:space:]:]+/)*[^[:space:]:]+:[0-9]+:##; s/^[[:space:]]*//; s/[[:space:]]*$//'
    )"
    is_agent_question_candidate "$question" || question=""
  fi

  [[ -n "$question" ]] || return 1
  printf '%s' "$question"
}

post_agent_clarification_question() {
  local issue="$1" repo="$2" phase="$3" question="$4" log_file="$5"
  agent_gh_issue_edit "$issue" --repo "$repo" --add-label "agent-question"
  agent-gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
## Agent clarification needed

${question}

Reply with \`/agent answer <your answers>\` and I will resume the \`${phase}\` phase automatically.

Local log: \`${log_file}\`
EOF
)"
}

extract_terminal_error() {
  local log_file="${1:-}"
  [[ -f "$log_file" ]] || return 1

  tail -n 200 "$log_file" | sed -n '/^ERROR:/p' | tail -n 1
}

extract_failure_summary() {
  local log_file="${1:-}" extra="${2:-}"
  local summary=""

  summary="$(extract_terminal_error "$log_file" || true)"

  if [[ -n "$extra" ]]; then
    if [[ -z "$summary" ]]; then
      summary="$(printf '%s' "$extra" | tail -n 5 | sed '/^[[:space:]]*$/d' | tail -n 3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    fi
  fi

  if [[ -z "$summary" && -f "$log_file" ]]; then
    summary="$(grep -E '"error"|"status":"failed"|Traceback|Error:|FAILED|exit code|No changes to commit|Knowledge file missing|verification failed' \
      "$log_file" 2>/dev/null | tail -n 3 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  fi

  if [[ -z "$summary" && -f "$log_file" ]]; then
    summary="$(tail -n 8 "$log_file" | sed '/^[[:space:]]*$/d' | tail -n 2 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  fi

  if [[ -z "$summary" ]]; then
    summary="Agent phase exited with an error."
  fi

  # Keep issue comments readable.
  if [[ ${#summary} -gt 500 ]]; then
    summary="${summary:0:497}..."
  fi
  printf '%s' "$summary"
}

summarize_agent_failure_from_log() {
  local log_file="${1:-}" extra="${2:-}"
  local fallback repo_root opencode_exec excerpt prompt response summary_tmp

  fallback="$(extract_failure_summary "$log_file" "$extra")"

  # Provider errors are already concise and reliable; avoid another OpenCode call.
  if extract_terminal_error "$log_file" >/dev/null; then
    printf '%s' "$fallback"
    return 0
  fi

  repo_root="$(agent_repo_root)"
  opencode_exec="${repo_root}/agent/scripts/agent-opencode-exec.sh"
  if [[ ! -x "$opencode_exec" ]]; then
    printf '%s' "$fallback"
    return 0
  fi

  excerpt="$(
    {
      [[ -n "$extra" ]] && printf 'Recent failure detail:\n%s\n\n' "$extra"
      [[ -f "$log_file" ]] && tail -n 120 "$log_file"
    } 2>/dev/null
  )"
  if [[ -z "$excerpt" ]]; then
    printf '%s' "$fallback"
    return 0
  fi

  prompt="$(cat <<EOF
You are agent. Read the failure evidence below and write exactly one short
human-facing sentence explaining why the agent run failed. Mention the concrete
error, failing stage, or blocker. Do not mention that you read logs. Output only
the sentence.

Failure evidence:
${excerpt}
EOF
)"

  summary_tmp="$(mktemp -d)"
  response="$(cd "$summary_tmp" && "$opencode_exec" "$prompt" 2>/dev/null || true)"
  rm -rf "$summary_tmp"
  response="$(sanitize_agent_progress_summary "$response")"
  if [[ -n "$response" ]]; then
    printf '%s' "$response"
  else
    printf '%s' "$fallback"
  fi
}

log_contains_blocked_command() {
  local log_file="${1:-}"
  [[ -f "$log_file" ]] || return 1
  grep -Eq 'blocked by policy|CreateProcess \{ message: "Rejected\(|exec_command failed for .*Rejected' "$log_file"
}

build_blocked_command_retry_prompt() {
  local original_prompt="$1"

  cat <<EOF
The previous agent attempt hit a blocked shell command. This is recoverable.

Do not repeat the blocked command. Read the run log/output, explain the blocked
command briefly to yourself, and work around it with a narrower allowed command
or a different non-destructive approach. Continue in the same working tree and
finish the original task.

Original task prompt:
${original_prompt}
EOF
}

build_pr_change_summary() {
  local base_branch="${1:-origin/main}"
  local max_files="${2:-20}"
  local files summary count=0

  if ! git rev-parse "$base_branch" >/dev/null 2>&1; then
    printf '%s' "_No diff against ${base_branch} available._"
    return 0
  fi

  mapfile -t files < <(git diff --name-only "$base_branch"...HEAD 2>/dev/null || true)
  if [[ ${#files[@]} -eq 0 ]]; then
    mapfile -t files < <(git diff --name-only HEAD~1..HEAD 2>/dev/null || true)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '%s' "_No file changes detected yet._"
    return 0
  fi

  summary="Changed files (${#files[@]}):"
  for path in "${files[@]}"; do
    [[ -z "$path" ]] && continue
    summary="${summary}"$'\n'"- \`${path}\`"
    count=$((count + 1))
    if [[ $count -ge $max_files ]]; then
      summary="${summary}"$'\n'"- _…and $(( ${#files[@]} - max_files )) more_"
      break
    fi
  done
  printf '%s' "$summary"
}

build_pr_version_note() {
  local base_branch="${1:-origin/main}"
  local files=()

  if git rev-parse "$base_branch" >/dev/null 2>&1; then
    mapfile -t files < <(git diff --name-only "$base_branch"...HEAD 2>/dev/null | sort)
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    mapfile -t files < <(git diff --name-only HEAD 2>/dev/null | sort)
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    mapfile -t files < <(git ls-files --others --exclude-standard 2>/dev/null | sort)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '%s' "This version does not change tracked files."
    return 0
  fi

  local max=3 shown=() file_list remaining
  for file in "${files[@]}"; do
    [[ -z "$file" ]] && continue
    shown+=("$file")
    [[ ${#shown[@]} -ge $max ]] && break
  done

  case "${#shown[@]}" in
    1) file_list="${shown[0]}" ;;
    2) file_list="${shown[0]} and ${shown[1]}" ;;
    *) file_list="${shown[0]}, ${shown[1]}, and ${shown[2]}" ;;
  esac

  remaining=$(( ${#files[@]} - ${#shown[@]} ))
  if [[ "$remaining" -gt 0 ]]; then
    printf 'This version updates %s, plus %s more file%s.' "$file_list" "$remaining" "$( [[ "$remaining" -eq 1 ]] && printf '' || printf 's' )"
  else
    printf 'This version updates %s.' "$file_list"
  fi
}

sanitize_pr_functional_summary() {
  local text="$1"
  text="$(printf '%s\n' "$text" \
    | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/^[[:space:]]*["'\'']//; s/["'\''][[:space:]]*$//' \
    | sed '/^[[:space:]]*$/d' \
    | head -n 1)"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  text="$(printf '%s' "$text" | cut -c1-240)"
  if [[ -n "$text" && ! "$text" =~ [.!?]$ ]]; then
    text="${text}."
  fi
  printf '%s' "$text"
}

build_pr_functional_summary() {
  local base_branch="${1:-origin/main}"
  local fallback summary_context prompt response opencode_exec repo_root

  fallback="$(build_pr_version_note "$base_branch")"
  if ! git rev-parse "$base_branch" >/dev/null 2>&1; then
    printf '%s' "$fallback"
    return 0
  fi

  if git diff --quiet "$base_branch"...HEAD -- 2>/dev/null; then
    printf '%s' "$fallback"
    return 0
  fi

  repo_root="$(agent_repo_root)"
  opencode_exec="${repo_root}/agent/scripts/agent-opencode-exec.sh"
  if [[ ! -x "$opencode_exec" ]]; then
    printf '%s' "$fallback"
    return 0
  fi

  summary_context="$(
    {
      echo "Diff stat:"
      git diff --stat "$base_branch"...HEAD -- 2>/dev/null || true
      echo
      echo "Diff excerpt:"
      git diff --unified=3 --no-ext-diff "$base_branch"...HEAD -- 2>/dev/null | head -c 12000 || true
    }
  )"

  prompt="$(cat <<EOF
You are agent. Based only on the diff context below, write exactly one short
human-facing sentence explaining what changed functionally in this version.
Do not list filenames unless the filename itself is the user-facing deliverable.
Do not mention tests, CI, git, commits, or implementation process. Output only
the sentence.

${summary_context}
EOF
)"

  local summary_tmp
  summary_tmp="$(mktemp -d)"
  response="$(cd "$summary_tmp" && "$opencode_exec" "$prompt" 2>/dev/null || true)"
  rm -rf "$summary_tmp"
  response="$(sanitize_pr_functional_summary "$response")"
  if [[ -n "$response" ]]; then
    printf '%s' "$response"
  else
    printf '%s' "$fallback"
  fi
}

agent_progress_state_file() {
  local issue="$1"
  echo "$(agent_goal_state_dir)/issue-${issue}-progress.tsv"
}

agent_progress_interval_sec() {
  printf '%s' "${AGENT_PROGRESS_INTERVAL_SEC:-300}"
}

agent_progress_report_due() {
  local elapsed_sec="${1:-0}" last_report_sec="${2:-0}"
  local interval

  if [[ "$elapsed_sec" -le 0 ]]; then
    printf '%s' false
    return 0
  fi

  if [[ "$elapsed_sec" -le 21600 ]]; then
    interval=3600
  else
    interval=21600
  fi

  if [[ $((elapsed_sec - last_report_sec)) -ge "$interval" ]]; then
    printf '%s' true
  else
    printf '%s' false
  fi
}

post_agent_longrun_started() {
  local issue="$1" repo="$2" phase="$3" detail="$4"

  agent-gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
## Agent run started

Working on phase \`${phase}\`.

${detail}

Progress updates will be posted hourly for the first 6 hours, then every 6 hours. Logs stay local on the runner under \`${AGENT_RUNS_DIR:-$(agent_runs_dir)}\`.
EOF
)"
}

post_agent_progress_update() {
  local issue="$1" repo="$2" phase="$3" detail="$4" pr_url="${5:-}"

  local pr_line=""
  if [[ -n "$pr_url" ]]; then
    pr_line=$'\n'"Draft PR: ${pr_url}"
  fi

agent-gh issue comment "$issue" --repo "$repo" --body "$(cat <<EOF
## Agent progress update

${detail}${pr_line}
EOF
)"
}

format_duration_minutes() {
  local seconds="${1:-0}"
  local minutes=$(( (seconds + 59) / 60 ))
  if [[ "$minutes" -le 0 ]]; then
    minutes=1
  fi
  printf '%sm' "$minutes"
}

agent_changed_file_count() {
  local count
  count="$( { git diff --name-only; git ls-files --others --exclude-standard; } 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u | wc -l | tr -d ' ' )"
  printf '%s' "${count:-0}"
}

sanitize_agent_progress_summary() {
  local text="$1"
  text="$(printf '%s\n' "$text" \
    | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/^[[:space:]]*["'\'']//; s/["'\''][[:space:]]*$//' \
    | sed '/^[[:space:]]*$/d' \
    | head -n 1)"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  text="$(printf '%s' "$text" | cut -c1-280)"
  if [[ -n "$text" && ! "$text" =~ [.!?]$ ]]; then
    text="${text}."
  fi
  printf '%s' "$text"
}

summarize_agent_progress_from_log() {
  local log_path="${1:-}"
  [[ -n "$log_path" && -f "$log_path" ]] || return 0

  local repo_root opencode_exec log_excerpt prompt response summary_tmp
  repo_root="$(agent_repo_root)"
  opencode_exec="${repo_root}/agent/scripts/agent-opencode-exec.sh"
  [[ -x "$opencode_exec" ]] || return 0

  log_excerpt="$(tail -c 12000 "$log_path" 2>/dev/null || true)"
  [[ -n "$log_excerpt" ]] || return 0

  prompt="$(cat <<EOF
You are agent. Read the recent run log excerpt below and write exactly one
brief human-facing sentence summarizing current progress. Include concrete counts,
percentages, ETA, output paths, or blockers if the log contains them. Do not
mention that you read a log. Output only the sentence.

Recent run log excerpt:
${log_excerpt}
EOF
)"

  summary_tmp="$(mktemp -d)"
  response="$(cd "$summary_tmp" && "$opencode_exec" "$prompt" 2>/dev/null || true)"
  rm -rf "$summary_tmp"
  sanitize_agent_progress_summary "$response"
}

agent_chunk_manifest_path() {
  local issue="$1" path
  for path in "res/issue-${issue}/manifest.json" "res/issue-${issue}/manifest.tsv"; do
    if [[ -f "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi
  done
  return 1
}

agent_chunk_progress_counts() {
  local manifest="$1"
  case "$manifest" in
    *.json)
      python3 - "$manifest" <<'PY' 2>/dev/null
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
chunks = data.get("chunks", data) if isinstance(data, dict) else data
if not isinstance(chunks, list):
    raise SystemExit(1)
total = len(chunks)
done = 0
for chunk in chunks:
    if isinstance(chunk, dict) and str(chunk.get("status", "")).lower() == "done":
        done += 1
print(f"{done} {total}")
PY
      ;;
    *.tsv)
      awk -F '\t' '
        NR == 1 {
          for (i = 1; i <= NF; i++) {
            if ($i == "status") status_col = i
          }
          if (status_col) next
          status_col = 2
        }
        NF {
          total += 1
          status = tolower($status_col)
          if (status == "done") done += 1
        }
        END {
          if (total > 0) print done, total
        }
      ' "$manifest"
      ;;
  esac
}

build_agent_chunk_progress_detail() {
  local issue="$1" elapsed_sec="${2:-0}"
  local manifest counts done total remaining_sec eta detail=""

  manifest="$(agent_chunk_manifest_path "$issue" 2>/dev/null || true)"
  [[ -n "$manifest" ]] || return 0

  counts="$(agent_chunk_progress_counts "$manifest" | tail -n 1)"
  read -r done total <<< "$counts"
  if ! [[ "$done" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$total" -gt 1 ]]; then
    return 0
  fi

  detail="- Chunks: ${done}/${total} done"
  if [[ "$done" -gt 0 && "$done" -lt "$total" && "$elapsed_sec" -gt 0 ]]; then
    remaining_sec=$(( elapsed_sec * (total - done) / done ))
    eta="$(date -u -d "+${remaining_sec} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    if [[ -n "$eta" ]]; then
      detail="${detail}
- ETA: ${eta}"
    else
      detail="${detail}
- ETA: about $(format_duration_minutes "$remaining_sec")"
    fi
  fi
  printf '%s' "$detail"
}

build_agent_progress_detail() {
  local issue="$1" phase="$2" elapsed_sec="${3:-0}" kind="${4:-goal}"
  local detail changed log_path progress_summary chunk_detail

  changed="$(agent_changed_file_count)"
  log_path="${AGENT_GOAL_LOG_FILE:-$(agent_goal_issue_run_dir "$issue")/latest.log}"
  detail="- Phase: \`${phase}\`
- Elapsed: $(format_duration_minutes "$elapsed_sec")
- Changed files: ${changed}
- Local log: \`${log_path}\`"
  progress_summary="$(summarize_agent_progress_from_log "$log_path")"
  chunk_detail="$(build_agent_chunk_progress_detail "$issue" "$elapsed_sec")"
  if [[ -n "$chunk_detail" ]]; then
    detail="${detail}
${chunk_detail}"
  fi
  if [[ -n "$progress_summary" ]]; then
    detail="${detail}
- Agent progress summary: ${progress_summary}"
  fi

  printf '%s' "$detail"
}

sync_intermediate_agent_artifacts() {
  local issue="$1" phase="$2" branch="$3" kind="${4:-goal}"
  local checkpoint tmp_checkpoint path

  checkpoint="$(agent_checkpoint_dir "$issue")"
  tmp_checkpoint="${checkpoint}.tmp"
  rm -rf "$tmp_checkpoint"
  mkdir -p "$tmp_checkpoint"

  if [[ "$kind" == "knowledge" ]]; then
    for path in "$(agent_knowledge_issue_dir_rel "$issue")"; do
      if [[ -d "$path" ]]; then
        mkdir -p "$tmp_checkpoint/$(dirname "$path")"
        cp -a "$path" "$tmp_checkpoint/$(dirname "$path")/"
      fi
    done
  else
    for path in "$(agent_goal_src_rel "$issue")" "$(agent_goal_results_rel "$issue")"; do
      if [[ -d "$path" ]]; then
        mkdir -p "$tmp_checkpoint/$(dirname "$path")"
        cp -a "$path" "$tmp_checkpoint/$(dirname "$path")/"
      fi
    done
  fi

  cat > "$tmp_checkpoint/metadata.env" <<EOF
issue=${issue}
phase=${phase}
branch=${branch}
kind=${kind}
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  rm -rf "$checkpoint"
  mv "$tmp_checkpoint" "$checkpoint"
}

clear_agent_checkpoint() {
  local issue="$1"
  rm -rf "$(agent_checkpoint_dir "$issue")" "$(agent_checkpoint_dir "$issue").tmp"
}

checkpoint_metadata_value() {
  local metadata_file="$1" key="$2"
  [[ -f "$metadata_file" ]] || return 1
  sed -n "s/^${key}=//p" "$metadata_file" | tail -n 1
}

restore_agent_checkpoint() {
  local issue="$1" phase="$2" branch="$3" kind="${4:-goal}"
  local checkpoint metadata_file checkpoint_issue checkpoint_phase checkpoint_branch checkpoint_kind path

  checkpoint="$(agent_checkpoint_dir "$issue")"
  [[ -d "$checkpoint" ]] || return 0

  if [[ ( "$kind" == "goal" && "$phase" != "implement" ) || \
        ( "$kind" == "knowledge" && "$phase" != "document" ) ]]; then
    echo "Ignoring checkpoint for issue #${issue}: phase '${phase}' uses the checked-out branch as its source of truth." >&2
    return 0
  fi

  metadata_file="$checkpoint/metadata.env"
  checkpoint_issue="$(checkpoint_metadata_value "$metadata_file" issue 2>/dev/null || true)"
  checkpoint_phase="$(checkpoint_metadata_value "$metadata_file" phase 2>/dev/null || true)"
  checkpoint_branch="$(checkpoint_metadata_value "$metadata_file" branch 2>/dev/null || true)"
  checkpoint_kind="$(checkpoint_metadata_value "$metadata_file" kind 2>/dev/null || true)"

  if [[ "$checkpoint_issue" != "$issue" || "$checkpoint_phase" != "$phase" || \
        "$checkpoint_branch" != "$branch" || "$checkpoint_kind" != "$kind" ]]; then
    echo "Ignoring stale checkpoint for issue #${issue}: metadata does not match ${kind}/${phase} on ${branch}." >&2
    return 0
  fi

  if [[ "$kind" == "knowledge" ]]; then
    for path in "$(agent_knowledge_issue_dir_rel "$issue")"; do
      if [[ -d "$checkpoint/$path" ]]; then
        mkdir -p "$(dirname "$path")"
        rm -rf "$path"
        cp -a "$checkpoint/$path" "$path"
      fi
    done
  else
    for path in "$(agent_goal_src_rel "$issue")" "$(agent_goal_results_rel "$issue")"; do
      if [[ -d "$checkpoint/$path" ]]; then
        mkdir -p "$(dirname "$path")"
        rm -rf "$path"
        cp -a "$checkpoint/$path" "$path"
      fi
    done
  fi

  echo "Restored matching ${kind}/${phase} checkpoint for issue #${issue} on ${branch}." >&2
  return 0
}

AGENT_PROGRESS_MONITOR_PID=""

stop_agent_progress_monitor() {
  if [[ -n "${AGENT_PROGRESS_MONITOR_PID:-}" ]]; then
    kill "$AGENT_PROGRESS_MONITOR_PID" 2>/dev/null || true
    wait "$AGENT_PROGRESS_MONITOR_PID" 2>/dev/null || true
    AGENT_PROGRESS_MONITOR_PID=""
  fi
}

start_agent_progress_monitor() {
  local issue="$1" repo="$2" phase="$3" branch="$4" kind="${5:-goal}" title="${6:-Agent work in progress}"

  local interval state_file
  interval="$(agent_progress_interval_sec)"
  state_file="$(agent_progress_state_file "$issue")"
  mkdir -p "$(agent_goal_state_dir)"

  (
    local tick=0 elapsed_sec=0 last_report_sec=0 pr_url=""
    while true; do
      sleep "$interval"
      tick=$((tick + 1))
      elapsed_sec=$((tick * interval))
      sync_agent_run_logs "$issue" "$phase" "" false || true
      if [[ ( "$kind" == "goal" && "$phase" == "implement" ) || \
            ( "$kind" == "knowledge" && "$phase" == "document" ) ]]; then
        sync_intermediate_agent_artifacts "$issue" "$phase" "$branch" "$kind" || true
      fi

      if [[ "$(agent_progress_report_due "$elapsed_sec" "$last_report_sec")" != "true" ]]; then
        continue
      fi

      if [[ -z "$pr_url" ]]; then
        if [[ "$kind" == "knowledge" ]]; then
          pr_url="$(find_open_pr_for_knowledge_issue "$issue" "$repo" 2>/dev/null | xargs -I{} agent-gh pr view {} --repo "$repo" --json url --jq .url 2>/dev/null || true)"
        else
          pr_url="$(find_open_pr_for_issue "$issue" "$repo" 2>/dev/null | xargs -I{} agent-gh pr view {} --repo "$repo" --json url --jq .url 2>/dev/null || true)"
        fi
        if [[ -z "$pr_url" ]]; then
          local body
          body="$(cat <<EOF
## Work in progress

Closes #${issue}

Periodic progress update while phase \`${phase}\` runs.

## Agent run

- Branch: \`${branch}\`
- Local log: \`${AGENT_GOAL_LOG_FILE:-$(agent_goal_issue_run_dir "$issue")/latest.log}\`
EOF
)"
          pr_url="$(agent-gh pr create --repo "$repo" --draft --base main --head "$branch" \
            --title "agent: ${title} (issue #${issue}, in progress)" \
            --body "$body" 2>/dev/null || true)"
          if [[ -n "$pr_url" ]]; then
            agent_gh_issue_edit "$issue" --repo "$repo" --add-label "agent-pr-open"
          fi
        fi
      fi

      post_agent_progress_update "$issue" "$repo" "$phase" \
        "$(build_agent_progress_detail "$issue" "$phase" "$elapsed_sec" "$kind")" "$pr_url" || true
      last_report_sec="$elapsed_sec"
      printf '%s\t%s\t%s\n' "$tick" "$phase" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$state_file"
    done
  ) &
  AGENT_PROGRESS_MONITOR_PID=$!
}

run_opencode_with_longrun_progress() {
  local issue="$1" repo="$2" phase="$3" branch="$4" kind="$5" title="$6"
  shift 6
  local prompt="$1"
  local src_dir results_dir knowledge_dir detail

  src_dir="$(agent_goal_src_rel "$issue")"
  results_dir="$(agent_goal_results_rel "$issue")"
  knowledge_dir="$(agent_knowledge_issue_dir_rel "$issue")"

  if [[ "$kind" == "goal" ]]; then
    detail="Implementation paths: \`${src_dir}/\`, \`${results_dir}/\`."
  else
    detail="Knowledge deliverables: \`${knowledge_dir}/\`."
  fi

  post_agent_longrun_started "$issue" "$repo" "$phase" "$detail"
  start_agent_progress_monitor "$issue" "$repo" "$phase" "$branch" "$kind" "$title"

  local repo_root opencode_exec
  repo_root="$(agent_repo_root)"
  opencode_exec="${repo_root}/agent/scripts/agent-opencode-exec.sh"

  local log_file="${AGENT_GOAL_LOG_FILE:-/dev/null}"

  set +e
  "$opencode_exec" "$prompt" 2>&1 | tee -a "$log_file"
  local opencode_status=${PIPESTATUS[0]}
  set -e

  if [[ "$opencode_status" -ne 0 ]] && log_contains_blocked_command "$log_file"; then
    {
      echo
      echo "==> agent: OpenCode command was blocked by policy; retrying once with recovery guidance."
    } | tee -a "$log_file"

    local retry_prompt
    retry_prompt="$(build_blocked_command_retry_prompt "$prompt")"
    set +e
    "$opencode_exec" "$retry_prompt" 2>&1 | tee -a "$log_file"
    opencode_status=${PIPESTATUS[0]}
    set -e
  fi

  stop_agent_progress_monitor
  return "$opencode_status"
}

record_phase_failure() {
  local issue="$1" log_file="$2" extra="${3:-}"
  local summary
  summary="$(extract_failure_summary "$log_file" "$extra")"
  write_agent_failure_summary "$issue" "$summary"
}

find_open_pr_for_knowledge_issue() {
  local issue="$1" repo="$2"
  agent-gh pr list --repo "$repo" --state open --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("agent/knowledge-issue-'"$issue"'-")) | .number' | head -1
}

find_latest_pr_for_knowledge_issue() {
  local issue="$1" repo="$2"
  agent-gh pr list --repo "$repo" --state all --limit 100 --json number,headRefName,updatedAt \
    --jq '[.[] | select(.headRefName | startswith("agent/knowledge-issue-'"$issue"'-"))] | sort_by(.updatedAt) | last | .number // empty'
}

find_branch_for_knowledge_issue() {
  local issue="$1" repo="$2"
  local pr branch
  pr="$(find_open_pr_for_knowledge_issue "$issue" "$repo")"
  if [[ -n "$pr" ]]; then
    branch="$(agent-gh pr view "$pr" --repo "$repo" --json headRefName --jq .headRefName)"
    printf '%s' "$branch"
    return 0
  fi
  branch="$(agent-git branch -r --list "origin/agent/knowledge-issue-${issue}-*" | head -1 | sed 's#^[[:space:]]*origin/##')"
  if [[ -n "$branch" ]]; then
    printf '%s' "$branch"
    return 0
  fi
  return 1
}

resolve_knowledge_issue_from_pr() {
  local pr="$1" repo="$2"
  agent-gh pr view "$pr" --repo "$repo" --json headRefName \
    --jq '.headRefName | capture("agent/knowledge-issue-(?<n>[0-9]+)-") | .n // empty'
}

read_agent_lock_info() {
  local info_file issue workflow started
  info_file="${1:-$(agent_machine_dir)/lock/agent.job.info}"
  if [[ ! -f "$info_file" ]]; then
    printf '%s' "another agent job"
    return 0
  fi
  issue="$(grep -E '^issue=' "$info_file" | cut -d= -f2- | tr -d '\r')"
  workflow="$(grep -E '^workflow=' "$info_file" | cut -d= -f2- | tr -d '\r')"
  started="$(grep -E '^started=' "$info_file" | cut -d= -f2- | tr -d '\r')"
  local desc="issue #${issue:-?}"
  if [[ -n "$workflow" ]]; then
    desc="${desc} (${workflow})"
  fi
  if [[ -n "$started" ]]; then
    desc="${desc}, started ${started}"
  fi
  printf '%s' "$desc"
}

busy_comment_state_file() {
  echo "$(agent_goal_state_dir)/busy-comments.tsv"
}

busy_comment_already_posted() {
  local comment_id="$1"
  [[ -z "$comment_id" ]] && return 1
  local state_file
  state_file="$(busy_comment_state_file)"
  [[ -f "$state_file" ]] || return 1
  grep -q "^${comment_id}	" "$state_file" 2>/dev/null
}

mark_busy_comment_posted() {
  local comment_id="$1" issue="$2"
  [[ -z "$comment_id" ]] && return 0
  local state_dir state_file
  state_dir="$(agent_goal_state_dir)"
  state_file="$(busy_comment_state_file)"
  mkdir -p "$state_dir"
  printf '%s\t%s\t%s\n' "$comment_id" "$issue" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$state_file"
}

post_agent_busy_comment() {
  local target_issue="$1" repo="$2" busy_detail="$3"

  agent-gh issue comment "$target_issue" --repo "$repo" --body "$(cat <<EOF
## Agent-abk is busy

Working on **${busy_detail}**.

Your request on this issue is **queued**. The backup poller (every 5 minutes) or a new trigger will retry after the current job finishes.

To check runner status locally: \`./agent/setup/status-github-runner.sh\`
EOF
)"
}
