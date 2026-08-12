#!/usr/bin/env bash
# Run OpenCode on the trusted self-hosted agent runner.
# OpenCode receives explicit auto-approval so agent jobs can use host GPUs,
# local runtimes, network resources, and project credentials.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-project-env.sh
source "$REPO_ROOT/agent/scripts/agent-project-env.sh"
# shellcheck source=agent-python-env.sh
source "$REPO_ROOT/agent/scripts/agent-python-env.sh"
agent_python_env_activate

execution_root="$REPO_ROOT"
if [[ "${1:-}" == "--cd" ]]; then
  execution_root="${2:?--cd requires a checkout path}"
  shift 2
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--cd checkout] <prompt>" >&2
  exit 1
fi

prompt="$1"
config_file="$execution_root/agent/opencode-profile.json"
if [[ ! -f "$config_file" ]]; then
  echo "Project OpenCode config not found: $config_file" >&2
  exit 1
fi

mapfile -t project_profile < <(python3 - "$config_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)

for key in ("model", "variant"):
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"Project OpenCode config is missing {key}: {sys.argv[1]}")
    print(value)
PY
)

if [[ ${#project_profile[@]} -ne 2 ]]; then
  echo "Could not read model profile from $config_file" >&2
  exit 1
fi

exec opencode run \
  --dir "$execution_root" \
  --auto \
  --agent autopilot \
  --model "${project_profile[0]}" \
  --variant "${project_profile[1]}" \
  "$prompt"
