#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$REPO_ROOT/agent/scripts/run-agent-knowledge.sh"

grep -Fq 'path="${line:3}"' "$RUNNER" && {
  echo "run-agent-knowledge.sh still strips the first character from porcelain paths" >&2
  exit 1
}

grep -Fq 'agent-git status --porcelain --untracked-files=all' "$RUNNER"
grep -Fq 'path="${line#???}"' "$RUNNER"
grep -Fq '[[ "$path" == "README.md" ]] && continue' "$RUNNER"
grep -Fq '[[ "$path" == "requirements.txt" ]] && continue' "$RUNNER"
grep -Fq 'agent-git add README.md' "$RUNNER"
grep -Fq 'agent-git add requirements.txt' "$RUNNER"

echo "knowledge commit preserves untracked checks OK"
