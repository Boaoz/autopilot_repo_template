#!/usr/bin/env bash
# One-time setup: register a self-hosted GitHub Actions runner for agent.
#
# Usage: ./agent/setup/setup-github-runner.sh [owner/repo] [--inspect]
#
# Installs the runner under ../machine/runner/github-actions (outside git).
# Requires repo admin access. Prefer running through agent/scripts/bin/agent-gh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

REPO="${GITHUB_REPOSITORY:-}"
PROFILE=agent
for arg in "$@"; do
  case "$arg" in
    --inspect) PROFILE=inspect ;;
    */*) REPO="$arg" ;;
    *) echo "Usage: $0 [owner/repo] [--inspect]" >&2; exit 2 ;;
  esac
done
REPO="${REPO:?GITHUB_REPOSITORY or repo argument is required}"

if [[ "$PROFILE" == "inspect" ]]; then
  RUNNER_DIR="${AGENT_INSPECT_RUNNER_DIR}"
  RUNNER_NAME="${RUNNER_NAME:-$(basename "$REPO_ROOT")-agent-inspect}"
  LABELS="${RUNNER_LABELS:-self-hosted,Linux,agent-inspect}"
else
  RUNNER_DIR="${AGENT_RUNNER_DIR}"
  RUNNER_NAME="${RUNNER_NAME:-$(basename "$REPO_ROOT")-agent}"
  LABELS="${RUNNER_LABELS:-self-hosted,Linux,agent}"
fi

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [[ ! -f ./config.sh ]]; then
  echo "Downloading actions-runner..."
  curl -sL -o actions-runner-linux-x64.tar.gz \
    https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz
  tar xzf actions-runner-linux-x64.tar.gz
  rm -f actions-runner-linux-x64.tar.gz
fi

echo "Fetching registration token for $REPO..."
TOKEN="$(agent-gh api -X POST "repos/${REPO}/actions/runners/registration-token" --jq .token)"

if [[ -f .runner ]]; then
  echo "Runner already configured in $RUNNER_DIR"
else
  ./config.sh \
    --url "https://github.com/${REPO}" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --unattended \
    --replace
fi

echo ""
echo "Runner configured at: $RUNNER_DIR"
profile_arg=""
[[ "$PROFILE" == "inspect" ]] && profile_arg=" --inspect"
echo "Start in screen:      ${REPO_ROOT}/agent/setup/start-github-runner.sh${profile_arg}"
echo "Check status:         ${REPO_ROOT}/agent/setup/status-github-runner.sh${profile_arg}"
echo "Stop:                 ${REPO_ROOT}/agent/setup/stop-github-runner.sh${profile_arg}"
echo ""
if [[ "$PROFILE" == "inspect" ]]; then
  echo "Attach to screen:     screen -r ${AGENT_INSPECT_RUNNER_SCREEN}"
else
  echo "Attach to screen:     screen -r ${AGENT_RUNNER_SCREEN}"
fi
