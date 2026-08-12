#!/usr/bin/env bash
# Start the agent GitHub Actions runner in a detached GNU screen session.
#
# Usage: ./agent/setup/start-github-runner.sh [owner/repo] [--inspect]
#
# Runner and logs live under ../machine/ (outside git). See agent/setup/README.md.

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
  SCREEN_NAME="${AGENT_INSPECT_RUNNER_SCREEN}"
  RUNNER_DIR="${AGENT_INSPECT_RUNNER_DIR}"
  LOG_FILE="${AGENT_INSPECT_RUNNER_LOG}"
  RUNNER_NAME="${RUNNER_NAME:-$(basename "$REPO_ROOT")-agent-inspect}"
else
  SCREEN_NAME="${AGENT_RUNNER_SCREEN}"
  RUNNER_DIR="${AGENT_RUNNER_DIR}"
  LOG_FILE="${AGENT_RUNNER_LOG}"
  RUNNER_NAME="${RUNNER_NAME:-$(basename "$REPO_ROOT")-agent}"
fi

mkdir -p "$(dirname "$LOG_FILE")"

if [[ ! -f "$RUNNER_DIR/run.sh" ]]; then
  profile_arg=""
  [[ "$PROFILE" == "inspect" ]] && profile_arg=" --inspect"
  echo "Runner not configured. Run ./agent/setup/setup-github-runner.sh${profile_arg} first." >&2
  exit 1
fi

if screen -list | grep -q "[[:space:]]*[0-9]*\.${SCREEN_NAME}[[:space:]]"; then
  echo "Runner screen '${SCREEN_NAME}' is already running."
  screen -list | grep "$SCREEN_NAME" || true
  exit 0
fi

screen -dmS "$SCREEN_NAME" bash -lc "
  set -eo pipefail
  source '${REPO_ROOT}/agent/scripts/agent-project-env.sh'
  cd '${RUNNER_DIR}'
  {
    echo \"[\$(date -u -Iseconds)] agent runner starting (screen=${SCREEN_NAME})\"
    exec ./run.sh
  } 2>&1 | tee -a '${LOG_FILE}'
"

sleep 2

if ! screen -list | grep -q "[[:space:]]*[0-9]*\.${SCREEN_NAME}[[:space:]]"; then
  echo "Failed to start screen session '${SCREEN_NAME}'." >&2
  exit 1
fi

if command -v gh >/dev/null; then
  agent-gh api "repos/${REPO}/actions/runners" --jq '.runners[] | select(.name=="'"${RUNNER_NAME}"'") | {name, status, busy}' 2>/dev/null || true
fi

echo "Started GitHub Actions runner in screen '${SCREEN_NAME}'."
echo "  Attach:  screen -r ${SCREEN_NAME}"
echo "  Log:     ${LOG_FILE}"
