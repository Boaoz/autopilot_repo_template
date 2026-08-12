#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-goal-lib.sh
source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

bad_log="$tmpdir/bad.log"
cat > "$bad_log" <<'EOF'
{"ts":"2026-07-07T16:25:12Z","phase":"plan","issue":1,"status":"started"}
+ set +e
plan_status=$?
{"ts":"2026-07-07T16:25:13Z","phase":"plan","issue":1,"status":"failed","error":"plan file empty"}
EOF

if extract_agent_question_from_log "$bad_log" >/tmp/agent-question.out 2>/dev/null; then
  echo "shell status snippets must not be treated as clarification questions" >&2
  cat /tmp/agent-question.out >&2
  exit 1
fi

good_log="$tmpdir/good.log"
cat > "$good_log" <<'EOF'
Implementation clarification needed:
Which of the two documented schemas should the importer treat as canonical?
EOF

question="$(extract_agent_question_from_log "$good_log")"
if [[ "$question" != "Which of the two documented schemas should the importer treat as canonical?" ]]; then
  echo "expected human-facing clarification question, got: $question" >&2
  exit 1
fi

multiple_log="$tmpdir/multiple.log"
cat > "$multiple_log" <<'EOF'
Planning clarification needed:
Which file format should the loader support?
Should malformed input raise an error or be skipped?
{"ts":"2026-07-07T16:25:13Z","phase":"plan","issue":1,"status":"paused"}
EOF

questions="$(extract_agent_question_from_log "$multiple_log")"
expected_questions=$'Which file format should the loader support?\nShould malformed input raise an error or be skipped?'
if [[ "$questions" != "$expected_questions" ]]; then
  echo "expected multiple clarification questions, got: $questions" >&2
  exit 1
fi

echo "clarification question extraction checks OK"
