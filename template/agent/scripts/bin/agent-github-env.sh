#!/usr/bin/env bash
# Load GitHub credentials for the agent bot account.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/agent/scripts/agent-project-env.sh"

CRED_FILE="${AGENT_GITHUB_CREDENTIALS}"

if [[ ! -f "$CRED_FILE" ]]; then
  echo "agent-github-env: credential file not found: $CRED_FILE" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ "$(stat -c '%a' "$CRED_FILE")" != "600" ]]; then
  echo "agent-github-env: warning: $CRED_FILE should be chmod 600" >&2
fi

eval "$(python3 - "$CRED_FILE" <<'PY'
import json, shlex, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    creds = json.load(fh)

username = creds["username"]
token = creds["access_token"]

print(f"export GH_USER={shlex.quote(username)}")
print(f"export AGENT_GITHUB_USERNAME={shlex.quote(username)}")
print(f"export GH_TOKEN={shlex.quote(token)}")
print(f"export GITHUB_TOKEN={shlex.quote(token)}")
print(f"export GIT_AUTHOR_NAME={shlex.quote(username)}")
print(f"export GIT_COMMITTER_NAME={shlex.quote(username)}")
print(f"export GIT_AUTHOR_EMAIL={shlex.quote(f'{username}@users.noreply.github.com')}")
print(f"export GIT_COMMITTER_EMAIL={shlex.quote(f'{username}@users.noreply.github.com')}")
PY
)"

export GH_PROMPT_DISABLED=1
export GIT_TERMINAL_PROMPT=0
