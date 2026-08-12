#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

assert_true() {
  local name="$1"
  shift
  if ! "$@"; then
    echo "expected true: $name" >&2
    exit 1
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    echo "expected false: $name" >&2
    exit 1
  fi
}

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $name to be [$expected], got [$actual]" >&2
    exit 1
  fi
}

assert_true "inspect accepts colon payload" is_inspect_comment "/agent inspect: what changed?"
assert_eq "what changed?" "$(strip_inspect_question "/agent inspect: what changed?")" "inspect colon payload"
assert_true "inspect accepts colon without following space" is_inspect_comment "/agent inspect:what changed?"
assert_eq "what changed?" "$(strip_inspect_question "/agent inspect:what changed?")" "inspect colon without following space"
assert_false "inspect rejects embedded command" is_inspect_comment "please /agent inspect what changed?"

assert_true "fix accepts colon payload" is_fix_comment "/agent fix: update docs"
assert_eq "update docs" "$(strip_fix_feedback "/agent fix: update docs")" "fix colon payload"
assert_false "fix rejects embedded command" is_fix_comment "please /agent fix update docs"
assert_false "fix rejects command prefix collision" is_fix_comment "/agent fixture update docs"

assert_true "revise accepts colon payload" is_revise_comment "/agent revise: tighten plan"
assert_eq "tighten plan" "$(strip_revise_feedback "/agent revise: tighten plan")" "revise colon payload"
assert_false "revise rejects embedded command" is_revise_comment "please /agent revise tighten plan"

assert_true "answer accepts colon payload" is_answer_comment "/agent answer: use API"
assert_eq "use API" "$(strip_answer_feedback "/agent answer: use API")" "answer colon payload"

assert_true "approve exact" is_approve_comment "/agent approve"
assert_true "retry exact" is_retry_comment "/agent retry"
assert_true "cancel exact" is_cancel_comment "/agent cancel"
assert_false "approve rejects suffix" is_approve_comment "/agent approve: now"
assert_false "cancel rejects suffix" is_cancel_comment "/agent cancel: now"

for workflow in "$REPO_ROOT"/.github/workflows/agent-{goal,fix,inspect,knowledge,cancel}.yml; do
  if grep -Fq "contains(github.event.comment.body, '/agent" "$workflow"; then
    echo "workflow should not use contains() for slash command matching: $workflow" >&2
    exit 1
  fi
done

grep -Fq "startsWith(github.event.comment.body, '/agent inspect')" "$REPO_ROOT/.github/workflows/agent-inspect.yml"
grep -Fq "startsWith(github.event.comment.body, '/agent fix')" "$REPO_ROOT/.github/workflows/agent-fix.yml"
grep -Fq "startsWith(github.event.comment.body, '/agent revise')" "$REPO_ROOT/.github/workflows/agent-goal.yml"

echo "slash command matching checks OK"
