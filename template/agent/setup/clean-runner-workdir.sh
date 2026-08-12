#!/usr/bin/env bash
# Remove ephemeral GitHub Actions runner cache (safe while runner is stopped).
#
# Usage: ./agent/setup/clean-runner-workdir.sh [--inspect]
#
# Deletes _work/ (job checkouts) and old _diag/ logs. Keeps the runner install.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

case "${1:-}" in
  --inspect) RUNNER_DIR="${AGENT_INSPECT_RUNNER_DIR}"; SCREEN_NAME="${AGENT_INSPECT_RUNNER_SCREEN}" ;;
  "") RUNNER_DIR="${AGENT_RUNNER_DIR}"; SCREEN_NAME="${AGENT_RUNNER_SCREEN}" ;;
  *) echo "Usage: $0 [--inspect]" >&2; exit 2 ;;
esac

if screen -list 2>/dev/null | grep -q "[[:space:]]*[0-9]*\.${SCREEN_NAME}[[:space:]]"; then
  echo "Stop this runner first: ./agent/setup/stop-github-runner.sh${1:+ --inspect}" >&2
  exit 1
fi

if [[ ! -d "$RUNNER_DIR" ]]; then
  echo "Runner directory not found: $RUNNER_DIR" >&2
  exit 1
fi

echo "==> Cleaning runner work cache: ${RUNNER_DIR}/_work"
rm -rf "${RUNNER_DIR}/_work"

echo "==> Cleaning runner diagnostic logs: ${RUNNER_DIR}/_diag"
rm -rf "${RUNNER_DIR}/_diag"
mkdir -p "${RUNNER_DIR}/_diag"

rm -f "${RUNNER_DIR}/.runner_migrated" 2>/dev/null || true

echo "Done. Runner install kept at: ${RUNNER_DIR}"
