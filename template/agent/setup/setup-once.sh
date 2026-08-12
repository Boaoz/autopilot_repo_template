#!/usr/bin/env bash
# One-command bootstrap for a new agent repository.
#
# Usage:
#   ./agent/setup/setup-once.sh owner/repo [--dry-run]
#
# This verifies the GitHub repository with agent credentials, pushes this
# checkout, creates labels, registers the self-hosted runner, and starts it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

REPO="${GITHUB_REPOSITORY:-}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    */*)
      REPO="$1"
      shift
      ;;
    *)
      echo "Usage: $0 owner/repo [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$REPO" || "$REPO" != */* ]]; then
  echo "Usage: $0 owner/repo [--dry-run]" >&2
  exit 1
fi

ORIGIN_URL="https://github.com/${REPO}.git"

say() {
  printf '%s\n' "$*"
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    say "Would run: $*"
  else
    "$@"
  fi
}

require_command() {
  local command="$1"
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
}

require_credentials() {
  if [[ ! -f "$AGENT_GITHUB_CREDENTIALS" ]]; then
    cat >&2 <<EOF
Missing agent credentials:
${AGENT_GITHUB_CREDENTIALS}

Create it with:
{"username":"agent","access_token":"ghp_..."}
EOF
    exit 1
  fi
  say "Credentials file OK: ${AGENT_GITHUB_CREDENTIALS}"
}

configure_origin() {
  if [[ "$DRY_RUN" == "true" ]]; then
    say "Would configure origin: ${ORIGIN_URL}"
    return
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$ORIGIN_URL"
  else
    git remote add origin "$ORIGIN_URL"
  fi
}

push_main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    say "Would push current branch as main with agent credentials"
    return
  fi

  git branch -M main
  agent-git push -u origin main
}

accept_agent_invite() {
  if [[ "$DRY_RUN" == "true" ]]; then
    say "Would accept collaborator invitation as agent"
    return
  fi

  local invitation_id
  invitation_id="$(
    agent/scripts/bin/agent-gh api user/repository_invitations \
      --jq '.[] | select(.repository.full_name == "'"${REPO}"'") | .id' \
      | head -1
  )"

  if [[ -z "$invitation_id" ]]; then
    if agent/scripts/bin/agent-gh api "repos/${REPO}" >/dev/null 2>&1; then
      say "agent already has access to ${REPO}"
      return
    fi
    echo "No pending invitation for agent on ${REPO}, and agent cannot access the repo." >&2
    exit 1
  fi

  agent/scripts/bin/agent-gh api -X PATCH "user/repository_invitations/${invitation_id}" >/dev/null
  say "agent accepted invitation to ${REPO}"
}

print_final_status() {
  cat <<EOF

One-command setup plan complete for ${REPO}.

Useful checks:
  ./agent/setup/status-github-runner.sh ${REPO}
  gh repo view ${REPO} --web

Next test:
  Open a GitHub issue labeled agent-goal or agent-knowledge.
EOF
}

cd "$REPO_ROOT"

require_command git
require_command gh
require_command screen
require_credentials
run ./agent/scripts/agent-python-env.sh install

configure_origin
push_main
accept_agent_invite
run ./agent/setup/setup-github-labels.sh "$REPO"
run ./agent/setup/setup-github-runner.sh "$REPO"
run ./agent/setup/start-github-runner.sh "$REPO"
run ./agent/setup/setup-github-runner.sh "$REPO" --inspect
run ./agent/setup/start-github-runner.sh "$REPO" --inspect
print_final_status
