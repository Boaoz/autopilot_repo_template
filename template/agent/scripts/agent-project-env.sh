#!/usr/bin/env bash
# Canonical project paths. Source from any repo script or agent/scripts/bin/* wrapper.

if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  REPO_ROOT="$(cd "${GITHUB_WORKSPACE}" && pwd)"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT
export AGENT_REPO_ROOT="${AGENT_REPO_ROOT:-$REPO_ROOT}"

AGENT_PROJECT_ROOT="${AGENT_PROJECT_ROOT:-$REPO_ROOT}"
export AGENT_PROJECT_ROOT

export AGENT_MACHINE_DIR="${AGENT_MACHINE_DIR:-${AGENT_PROJECT_ROOT}/machine}"
export AGENT_RUNS_DIR="${AGENT_RUNS_DIR:-${AGENT_MACHINE_DIR}/runs}"
export AGENT_GITHUB_CREDENTIALS="${AGENT_GITHUB_CREDENTIALS:-${AGENT_PROJECT_ROOT}/credentials/github_agent.txt}"
export AGENT_CLICKHOUSE_CREDENTIALS="${AGENT_CLICKHOUSE_CREDENTIALS:-${AGENT_PROJECT_ROOT}/credentials/agent_clickhouse_login.txt}"
export AGENT_RUNNER_DIR="${AGENT_RUNNER_DIR:-${AGENT_MACHINE_DIR}/runner/github-actions}"
export AGENT_RUNNER_LOG="${AGENT_RUNNER_LOG:-${AGENT_MACHINE_DIR}/logs/runner.log}"
export AGENT_INSPECT_RUNNER_DIR="${AGENT_INSPECT_RUNNER_DIR:-${AGENT_MACHINE_DIR}/runner/github-actions-inspect}"
export AGENT_INSPECT_RUNNER_LOG="${AGENT_INSPECT_RUNNER_LOG:-${AGENT_MACHINE_DIR}/logs/runner-inspect.log}"
repo_name="$(basename "$REPO_ROOT")"
repo_slug="$(printf '%s' "$repo_name" | tr -c 'A-Za-z0-9_.-' '-')"
export AGENT_RUNNER_SCREEN="${AGENT_RUNNER_SCREEN:-agent-${repo_slug}-runner}"
export AGENT_INSPECT_RUNNER_SCREEN="${AGENT_INSPECT_RUNNER_SCREEN:-agent-${repo_slug}-inspect-runner}"

export PATH="${REPO_ROOT}/agent/scripts/bin:${PATH}"
