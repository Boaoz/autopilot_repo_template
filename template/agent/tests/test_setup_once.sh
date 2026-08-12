#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/agent/setup/setup-once.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "setup-once.sh must exist and be executable" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export AGENT_PROJECT_ROOT="$tmpdir/project"
export AGENT_MACHINE_DIR="$tmpdir/project/machine"
mkdir -p "$tmpdir/project/credentials"
printf '{"username":"agent","access_token":"ghp_fake"}\n' > "$tmpdir/project/credentials/github_agent.txt"
chmod 600 "$tmpdir/project/credentials/github_agent.txt"

output="$("$SCRIPT" example/agent-template-target --dry-run)"

grep -Fq "Would configure origin: https://github.com/example/agent-template-target.git" <<< "$output"
grep -Fq "Would push current branch as main with agent credentials" <<< "$output"
grep -Fq "Would accept collaborator invitation as agent" <<< "$output"
grep -Fq "Credentials file OK:" <<< "$output"
grep -Fq "Would run: ./agent/setup/setup-github-labels.sh example/agent-template-target" <<< "$output"
grep -Fq "Would run: ./agent/setup/setup-github-runner.sh example/agent-template-target" <<< "$output"
grep -Fq "Would run: ./agent/setup/start-github-runner.sh example/agent-template-target" <<< "$output"
grep -Fq "Would run: ./agent/setup/setup-github-runner.sh example/agent-template-target --inspect" <<< "$output"
grep -Fq "Would run: ./agent/setup/start-github-runner.sh example/agent-template-target --inspect" <<< "$output"
grep -Fq "Would run: ./agent/scripts/agent-python-env.sh install" <<< "$output"
grep -Fq "One-command setup plan complete" <<< "$output"

echo "setup-once dry-run checks OK"
