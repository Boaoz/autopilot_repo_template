#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STOP_SCRIPT="$REPO_ROOT/agent/setup/stop-github-runner.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

state_file="$tmpdir/screens"
calls_file="$tmpdir/calls"
printf '%s\n' main-screen inspect-screen unrelated-screen > "$state_file"

cat > "$tmpdir/screen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_SCREEN_CALLS:?}"
if [[ "${1:-}" == "-list" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf '  123.%s\t(Detached)\n' "$name"
  done < "${FAKE_SCREEN_STATE:?}"
  exit 0
fi

if [[ "${1:-}" == "-S" ]]; then
  target="${2:-}"
  grep -Fxv "$target" "$FAKE_SCREEN_STATE" > "${FAKE_SCREEN_STATE}.tmp" || true
  mv "${FAKE_SCREEN_STATE}.tmp" "$FAKE_SCREEN_STATE"
  exit 0
fi

exit 1
EOF
chmod +x "$tmpdir/screen"

export PATH="$tmpdir:$PATH"
export FAKE_SCREEN_STATE="$state_file"
export FAKE_SCREEN_CALLS="$calls_file"
export AGENT_RUNNER_SCREEN=main-screen
export AGENT_INSPECT_RUNNER_SCREEN=inspect-screen

"$STOP_SCRIPT"
"$STOP_SCRIPT" --inspect

grep -Fq -- '-S main-screen -p 0 -X stuff' "$calls_file"
grep -Fq -- '-S inspect-screen -p 0 -X stuff' "$calls_file"
grep -Fxq unrelated-screen "$state_file"
if grep -Eq '^(main-screen|inspect-screen)$' "$state_file"; then
  echo "shutdown left an agent runner screen active" >&2
  exit 1
fi

echo "shutdown runner checks OK"
