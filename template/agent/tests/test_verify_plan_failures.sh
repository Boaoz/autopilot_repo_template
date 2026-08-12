#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

plan_file="$tmp_dir/plan.md"
cat > "$plan_file" <<'EOF'
<!-- agent-verify
python3 -c 'raise SystemExit(7)'
-->
EOF

if "$REPO_ROOT/agent/scripts/verify.sh" --plan "$plan_file" >/tmp/verify-plan-failure.out 2>/tmp/verify-plan-failure.err; then
  echo "verify.sh succeeded despite a failing agent-verify command" >&2
  cat /tmp/verify-plan-failure.out >&2
  cat /tmp/verify-plan-failure.err >&2
  exit 1
fi

if ! grep -q "command failed" /tmp/verify-plan-failure.err; then
  echo "verify.sh did not report the failing plan command" >&2
  cat /tmp/verify-plan-failure.out >&2
  cat /tmp/verify-plan-failure.err >&2
  exit 1
fi

missing_plan="$tmp_dir/missing-plan.md"
if "$REPO_ROOT/agent/scripts/verify.sh" --plan "$missing_plan" >/tmp/verify-missing-plan.out 2>/tmp/verify-missing-plan.err; then
  echo "verify.sh succeeded despite a missing plan file" >&2
  cat /tmp/verify-missing-plan.out >&2
  cat /tmp/verify-missing-plan.err >&2
  exit 1
fi

if ! grep -q "Plan file not found" /tmp/verify-missing-plan.err; then
  echo "verify.sh did not report the missing plan file" >&2
  cat /tmp/verify-missing-plan.out >&2
  cat /tmp/verify-missing-plan.err >&2
  exit 1
fi

broad_pytest_plan="$tmp_dir/broad-pytest-plan.md"
cat > "$broad_pytest_plan" <<'EOF'
<!-- agent-verify
python -m pytest tests src/issue-7
-->
EOF

if "$REPO_ROOT/agent/scripts/verify.sh" --plan "$broad_pytest_plan" >/tmp/verify-broad-pytest.out 2>/tmp/verify-broad-pytest.err; then
  echo "verify.sh accepted a broad pytest command against repository-level agent/tests/" >&2
  cat /tmp/verify-broad-pytest.out >&2
  cat /tmp/verify-broad-pytest.err >&2
  exit 1
fi

grep -Fq "Do not run repository-level agent/tests/ from an agent-goal plan" /tmp/verify-broad-pytest.err

mkdir -p "$tmp_dir/bin" "$tmp_dir/src/issue-22"
cat > "$tmp_dir/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$tmp_dir/bin/python"
cat > "$tmp_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "python3 fallback ran: $*"
EOF
chmod +x "$tmp_dir/bin/python3"
cat > "$tmp_dir/issue-22-plan.md" <<'EOF'
<!-- agent-verify
python -m pytest src/issue-22 -q
-->
EOF

if AGENT_SKIP_PYTHON_ENV=1 PATH="$tmp_dir/bin:$PATH" "$REPO_ROOT/agent/scripts/verify.sh" --plan "$tmp_dir/issue-22-plan.md" >/tmp/verify-python-fallback.out 2>/tmp/verify-python-fallback.err; then
  :
else
  echo "verify.sh did not rewrite unavailable python to python3" >&2
  cat /tmp/verify-python-fallback.out >&2
  cat /tmp/verify-python-fallback.err >&2
  exit 1
fi

grep -Fq "python3 fallback ran: -m pytest src/issue-22 -q" /tmp/verify-python-fallback.out
grep -Fq "python unavailable; using python3" /tmp/verify-python-fallback.err

mkdir -p "$tmp_dir/no-agent/tests/src/issue-30" "$tmp_dir/no-agent/tests/agent/scripts"
cp "$REPO_ROOT/agent/scripts/verify.sh" "$tmp_dir/no-agent/tests/agent/scripts/verify.sh"
cp "$REPO_ROOT/agent/scripts/agent-python-env.sh" "$tmp_dir/no-agent/tests/agent/scripts/agent-python-env.sh"
cp "$REPO_ROOT/agent/scripts/agent-goal-lib.sh" "$tmp_dir/no-agent/tests/agent/scripts/agent-goal-lib.sh"
cat > "$tmp_dir/no-agent/tests/src/issue-30/tool.py" <<'PY'
print("ok")
PY
cat > "$tmp_dir/no-tests-plan.md" <<EOF
<!-- agent-verify
python3 -m pytest $tmp_dir/no-agent/tests/src/issue-30 -q
-->
EOF

if "$tmp_dir/no-agent/tests/agent/scripts/verify.sh" --plan "$tmp_dir/no-tests-plan.md" >"$tmp_dir/no-tests.out" 2>"$tmp_dir/no-tests.err"; then
  :
else
  echo "verify.sh should skip pytest commands with no collected tests" >&2
  cat "$tmp_dir/no-tests.out" >&2
  cat "$tmp_dir/no-tests.err" >&2
  exit 1
fi

grep -Fq "pytest collected no tests; skipping" "$tmp_dir/no-tests.err"

mkdir -p "$tmp_dir/default-after-plan/src/issue-31" "$tmp_dir/default-after-plan/agent/scripts"
cp "$REPO_ROOT/agent/scripts/verify.sh" "$tmp_dir/default-after-plan/agent/scripts/verify.sh"
cp "$REPO_ROOT/agent/scripts/agent-python-env.sh" "$tmp_dir/default-after-plan/agent/scripts/agent-python-env.sh"
cp "$REPO_ROOT/agent/scripts/agent-goal-lib.sh" "$tmp_dir/default-after-plan/agent/scripts/agent-goal-lib.sh"
cat > "$tmp_dir/default-after-plan/src/issue-31/broken.py" <<'PY'
def bad(:
    pass
PY
cat > "$tmp_dir/default-after-plan-plan.md" <<'EOF'
<!-- agent-verify
python3 -c 'print("custom check passed")'
-->
EOF

if (
  cd "$tmp_dir/default-after-plan"
  ./agent/scripts/verify.sh --plan "$tmp_dir/default-after-plan-plan.md" >"$tmp_dir/default-after-plan.out" 2>"$tmp_dir/default-after-plan.err"
); then
  echo "verify.sh should still run default checks after custom plan commands" >&2
  cat "$tmp_dir/default-after-plan.out" >&2
  cat "$tmp_dir/default-after-plan.err" >&2
  exit 1
fi

grep -Fq "custom check passed" "$tmp_dir/default-after-plan.out"
grep -Fq "==> verify: compile Python sources" "$tmp_dir/default-after-plan.out"

echo "verify plan failure checks OK"
