#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

log_file="$tmpdir/phase.jsonl"
for index in $(seq 1 205); do
  printf 'ordinary log line %s\n' "$index" >> "$log_file"
done
printf '%s\n' \
  'ERROR: earlier provider error' \
  'ordinary trailing output' \
  'ERROR: exceeded retry limit, last status: 429 Too Many Requests, request id: test-request' \
  '{"status":"failed","error":"OpenCode implement failed"}' >> "$log_file"

expected='ERROR: exceeded retry limit, last status: 429 Too Many Requests, request id: test-request'
[[ "$(extract_terminal_error "$log_file")" == "$expected" ]]
[[ "$(extract_failure_summary "$log_file" 'generic wrapper failure')" == "$expected" ]]

mkdir -p "$tmpdir/repo/agent/scripts"
cat > "$tmpdir/repo/agent/scripts/agent-opencode-exec.sh" <<'EOF'
#!/usr/bin/env bash
touch "${SUMMARY_OPENCODE_CALLED:?}"
printf '%s\n' 'unexpected OpenCode summary'
EOF
chmod +x "$tmpdir/repo/agent/scripts/agent-opencode-exec.sh"

agent_repo_root() { printf '%s' "$tmpdir/repo"; }
export SUMMARY_OPENCODE_CALLED="$tmpdir/opencode-called"

[[ "$(summarize_agent_failure_from_log "$log_file" 'generic wrapper failure')" == "$expected" ]]
[[ ! -e "$SUMMARY_OPENCODE_CALLED" ]]

echo "failure summary ERROR fallback checks OK"
