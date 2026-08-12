#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/checkout/agent" "$tmpdir/bin"
cat > "$tmpdir/checkout/agent/opencode-profile.json" <<'EOF'
{
  "model": "xai/grok-build-0.1",
  "variant": "high"
}
EOF

cat > "$tmpdir/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_OPENCODE_ARGS:?}"
EOF
chmod +x "$tmpdir/bin/opencode"

export PATH="$tmpdir/bin:$PATH"
export FAKE_OPENCODE_ARGS="$tmpdir/args"
export AGENT_PROJECT_ROOT="$REPO_ROOT"

"$REPO_ROOT/agent/scripts/agent-opencode-exec.sh" --cd "$tmpdir/checkout" "test prompt"

grep -Fxq -- '--dir' "$tmpdir/args"
grep -Fxq -- "$tmpdir/checkout" "$tmpdir/args"
grep -Fxq -- '--auto' "$tmpdir/args"
grep -Fxq -- '--agent' "$tmpdir/args"
grep -Fxq -- 'autopilot' "$tmpdir/args"
grep -Fxq -- '--model' "$tmpdir/args"
grep -Fxq -- 'xai/grok-build-0.1' "$tmpdir/args"
grep -Fxq -- '--variant' "$tmpdir/args"
grep -Fxq -- 'high' "$tmpdir/args"
grep -Fxq -- 'test prompt' "$tmpdir/args"

echo "OpenCode project profile checks OK"
