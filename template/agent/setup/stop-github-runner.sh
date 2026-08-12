#!/usr/bin/env bash
# Gracefully stop one repository-specific agent runner and close its screens.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"

case "${1:-}" in
  --inspect)
    SCREEN_NAME="${AGENT_INSPECT_RUNNER_SCREEN}"
    SCREEN_SUFFIX="-${repo_slug}-inspect-runner"
    ;;
  "")
    SCREEN_NAME="${AGENT_RUNNER_SCREEN}"
    SCREEN_SUFFIX="-${repo_slug}-runner"
    ;;
  *) echo "Usage: $0 [--inspect]" >&2; exit 2 ;;
esac

mapfile -t SCREEN_NAMES < <(
  screen -list 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*\.\([^[:space:]]*\)[[:space:]].*$/\1/p' \
    | awk -v exact="$SCREEN_NAME" -v suffix="$SCREEN_SUFFIX" \
        '$0 == exact || (length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix)'
)

if [[ ${#SCREEN_NAMES[@]} -eq 0 ]]; then
  echo "Runner screen '${SCREEN_NAME}' is not running."
  exit 0
fi

for candidate in "${SCREEN_NAMES[@]}"; do
  echo "Requesting graceful shutdown of runner screen '${candidate}'..."
  screen -S "$candidate" -p 0 -X stuff $'\003' || true
done

for _attempt in $(seq 1 15); do
  remaining=false
  for candidate in "${SCREEN_NAMES[@]}"; do
    if screen -list 2>/dev/null | grep -q "[[:space:]]*[0-9]*\.${candidate}[[:space:]]"; then
      remaining=true
      break
    fi
  done
  [[ "$remaining" == "false" ]] && break
  sleep 1
done

for candidate in "${SCREEN_NAMES[@]}"; do
  if screen -list 2>/dev/null | grep -q "[[:space:]]*[0-9]*\.${candidate}[[:space:]]"; then
    echo "Runner screen '${candidate}' did not exit after 15 seconds; closing it."
    screen -S "$candidate" -X quit || true
  fi
  echo "Stopped runner screen '${candidate}'."
done
