#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GOAL_RUNNER="$REPO_ROOT/agent/scripts/run-agent-goal.sh"
FOLLOWUP_SCRIPT="$REPO_ROOT/agent/scripts/agent-followup-after-merge.sh"
CREATE_FOLLOWUP_SCRIPT="$REPO_ROOT/agent/scripts/agent-create-followup-goal.sh"
FOLLOWUP_WORKFLOW="$REPO_ROOT/.github/workflows/agent-followup-after-merge.yml"

if grep -Fq "followup_goal_rules" "$GOAL_RUNNER" ||
   grep -Fq "maybe_create_followup_goal_issue" "$GOAL_RUNNER" ||
   grep -Fq "agent-create-followup-goal.sh" "$GOAL_RUNNER"; then
  echo "agent-goal implement/fix phases must not create follow-up issues" >&2
  exit 1
fi

[[ -x "$FOLLOWUP_SCRIPT" ]]

grep -Fq "pull_request:" "$FOLLOWUP_WORKFLOW"
grep -Fq "types: [closed]" "$FOLLOWUP_WORKFLOW"
grep -Fq "github.event.pull_request.merged == true" "$FOLLOWUP_WORKFLOW"
grep -Fq "./agent/scripts/agent-followup-after-merge.sh" "$FOLLOWUP_WORKFLOW"

grep -Fq "baseRefName" "$FOLLOWUP_SCRIPT"
grep -Eq "state.*CLOSED|CLOSED.*state" "$FOLLOWUP_SCRIPT"
grep -Fq "agent-create-followup-goal.sh" "$FOLLOWUP_SCRIPT"
grep -Fq "followup-after-merge.tsv" "$FOLLOWUP_SCRIPT"

grep -Fq 'Follow-up to #${SOURCE_ISSUE}.' "$CREATE_FOLLOWUP_SCRIPT"
if grep -Fq "should not be folded into the current PR" "$CREATE_FOLLOWUP_SCRIPT" ||
   grep -Fq "A human must review this plan" "$CREATE_FOLLOWUP_SCRIPT"; then
  echo "follow-up issue body must not include stale workflow boilerplate" >&2
  exit 1
fi

echo "follow-up after merge checks OK"
