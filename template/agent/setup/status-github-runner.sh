#!/usr/bin/env bash
# Show agent runner screen + GitHub registration status.

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
  LOG_FILE="${AGENT_INSPECT_RUNNER_LOG}"
  RUNNER_DIR="${AGENT_INSPECT_RUNNER_DIR}"
else
  SCREEN_NAME="${AGENT_RUNNER_SCREEN}"
  LOG_FILE="${AGENT_RUNNER_LOG}"
  RUNNER_DIR="${AGENT_RUNNER_DIR}"
fi

echo "==> Screen sessions"
screen -list 2>/dev/null | grep -E "(${SCREEN_NAME}|There are)" || echo "(no screen named ${SCREEN_NAME})"

echo ""
echo "==> Runner process"
pgrep -af 'Runner.Listener' || echo "(Runner.Listener not running)"

echo ""
echo "==> GitHub runner registration"
if command -v gh >/dev/null; then
  agent-gh api "repos/${REPO}/actions/runners" \
    --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}' 2>/dev/null || echo "(could not query GitHub)"
else
  echo "(gh not installed)"
fi

echo ""
echo "==> Project paths"
echo "  repo:    ${AGENT_REPO_ROOT}"
echo "  machine: ${AGENT_MACHINE_DIR}"
echo "  creds:   ${AGENT_GITHUB_CREDENTIALS}"
echo "  runner:  ${RUNNER_DIR}"

echo ""
echo "==> Recent log (${LOG_FILE})"
if [[ -f "$LOG_FILE" ]]; then
  tail -n 15 "$LOG_FILE"
else
  echo "(no log yet)"
fi
