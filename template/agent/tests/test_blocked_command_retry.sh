#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

# shellcheck source=/dev/null
source "$LIB"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/agent/scripts"
state_file="$tmpdir/invocations"
log_file="$tmpdir/OpenCode.log"
prompt_file="$tmpdir/retry-prompt.txt"

cat > "$tmpdir/agent/scripts/agent-opencode-exec.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${FAKE_OPENCODE_STATE:?}"
prompt_file="${FAKE_OPENCODE_PROMPT:?}"
count=0
if [[ -f "$state_file" ]]; then
  count="$(cat "$state_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$state_file"

if [[ "$count" -eq 1 ]]; then
  echo 'ERROR OpenCode_core::tools::router: error=exec_command failed for `/bin/sh -lc rm -rf cache`: CreateProcess { message: "Rejected(\"blocked by policy\")" }'
  exit 1
fi

printf '%s' "$1" > "$prompt_file"
echo "recovered after blocked command"
exit 0
EOF
chmod +x "$tmpdir/agent/scripts/agent-opencode-exec.sh"

agent_repo_root() { printf '%s' "$tmpdir"; }
post_agent_longrun_started() { :; }
start_agent_progress_monitor() { :; }
stop_agent_progress_monitor() { :; }

export AGENT_GOAL_LOG_FILE="$log_file"
export FAKE_OPENCODE_STATE="$state_file"
export FAKE_OPENCODE_PROMPT="$prompt_file"

run_opencode_with_longrun_progress 9 Boaoz/regulations-test3 implement test-branch goal "Blocked command retry" "original prompt"

[[ "$(cat "$state_file")" == "2" ]]
grep -Fq "blocked shell command" "$prompt_file"
grep -Fq "work around it with a narrower allowed command" "$prompt_file"
grep -Fq "recovered after blocked command" "$log_file"

echo "blocked command retry checks OK"
