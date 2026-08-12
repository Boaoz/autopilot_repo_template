#!/usr/bin/env bash
# Repository verification — used by the agent implement/fix phases and CI.
#
# Usage:
#   ./agent/scripts/verify.sh
#   ./agent/scripts/verify.sh --plan /path/to/plan.md   # plan block + default checks
#   ./agent/scripts/verify.sh --workflow                # default checks + framework tests

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=agent-python-env.sh
source "$REPO_ROOT/agent/scripts/agent-python-env.sh"
agent_python_env_activate
cd "$REPO_ROOT"

check_file_size_limits() {
  echo "==> verify: GitHub file size limits"
  # shellcheck source=agent-goal-lib.sh
  source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
  check_github_file_size_limit_for_repo "$REPO_ROOT"
}

resolve_src_dirs() {
  local plan_file="${1:-}" src_dirs=()

  if [[ -n "$plan_file" && -f "$plan_file" ]]; then
    # shellcheck source=agent-goal-lib.sh
    source "$REPO_ROOT/agent/scripts/agent-goal-lib.sh"
    local issue target
    issue="$(basename "$(dirname "$plan_file")" | sed -n 's/^issue-\([0-9]*\)$/\1/p')"
    if [[ -n "$issue" ]]; then
      target="$(read_src_target_from_plan "$plan_file" "$issue")"
      if [[ -d "$target" ]]; then
        src_dirs+=("$target")
      fi
    fi
  fi

  if [[ ${#src_dirs[@]} -eq 0 && -d src ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && src_dirs+=("$dir")
    done < <(find src -mindepth 1 -maxdepth 1 -type d -name 'issue-*' | sort)
  fi

  if [[ ${#src_dirs[@]} -eq 0 && -d src ]]; then
    src_dirs+=(src)
  fi

  printf '%s\n' "${src_dirs[@]}"
}

run_default_verify() {
  local plan_file="${PLAN_FILE:-}"
  local src_dirs=()
  mapfile -t src_dirs < <(resolve_src_dirs "$plan_file")

  echo "==> verify: compile Python sources"
  for src_dir in "${src_dirs[@]}"; do
    [[ -n "$src_dir" && -d "$src_dir" ]] || continue
    while IFS= read -r -d '' py_file; do
      python3 -m py_compile "$py_file"
    done < <(find "$src_dir" -name '*.py' -not -path '*/__pycache__/*' -print0 2>/dev/null || true)
  done

  if [[ -f src/code/1_hello.py ]]; then
    echo "==> verify: run src/code/1_hello.py"
    python3 src/code/1_hello.py
  fi

  local has_tests=false
  for src_dir in "${src_dirs[@]}"; do
    [[ -n "$src_dir" && -d "$src_dir" ]] || continue
    if find "$src_dir" -name '*test*.py' -print -quit | grep -q .; then
      has_tests=true
      break
    fi
  done

  if [[ "$has_tests" == "true" ]]; then
    echo "==> verify: unit tests"
    if python3 -m pytest --version >/dev/null 2>&1; then
      for src_dir in "${src_dirs[@]}"; do
        [[ -n "$src_dir" && -d "$src_dir" ]] || continue
        if ! find "$src_dir" -name '*test*.py' -print -quit | grep -q .; then
          continue
        fi
        python3 -m pytest "$src_dir/" -q
      done
    else
      for src_dir in "${src_dirs[@]}"; do
        [[ -n "$src_dir" && -d "$src_dir" ]] || continue
        while IFS= read -r test_file; do
          python3 "$test_file"
        done < <(find "$src_dir" -name '*test*.py' | sort)
      done
    fi
  fi

  check_file_size_limits

}

run_workflow_verify() {
  run_default_verify

  if ! find agent/tests -name 'test_*.sh' -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi

  echo "==> verify: workflow shell tests"
  while IFS= read -r test_file; do
    bash "$test_file"
  done < <(find agent/tests -name 'test_*.sh' | sort)
}

run_plan_verify() {
  local plan_file="$1"
  local in_block=false
  local ran=false

  rejects_repo_level_pytest() {
    local command="$1"
    [[ "$command" == *pytest* && ( " $command " == *" tests "* || " $command " == *" agent/tests "* ) ]]
  }

  run_plan_command() {
    local command="$1"
    if rejects_repo_level_pytest "$command"; then
      echo "Do not run repository-level agent/tests/ from an agent-goal plan; use issue-scoped tests such as python -m pytest src/issue-<N>/ -q plus ./agent/scripts/verify.sh." >&2
      return 1
    fi
    if [[ "$command" == python\ * ]] && ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      echo "==> verify (plan): python unavailable; using python3 for: $command" >&2
      command="python3 ${command#python }"
    fi
    set +e
    bash -c "$command"
    local status=$?
    set -e
    if [[ "$status" -eq 127 && "$command" == python\ * ]] && command -v python3 >/dev/null 2>&1; then
      echo "==> verify (plan): python unavailable; using python3 for: $command" >&2
      bash -c "python3 ${command#python }"
      status=$?
    fi
    if [[ "$status" -eq 5 && ( "$command" == *"pytest"* || "$command" == *"py.test"* ) ]]; then
      echo "==> verify (plan): pytest collected no tests; skipping: $command" >&2
      return 0
    fi
    return "$status"
  }

  if [[ ! -f "$plan_file" ]]; then
    echo "Plan file not found: $plan_file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"<!-- agent-verify"* ]]; then
      in_block=true
      continue
    fi
    if [[ "$in_block" == "true" && "$line" == *"-->"* ]]; then
      break
    fi
    if [[ "$in_block" == "true" ]]; then
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      echo "==> verify (plan): $line"
      if ! run_plan_command "$line"; then
        echo "==> verify (plan): command failed: $line" >&2
        return 1
      fi
      ran=true
    fi
  done < "$plan_file"

  if [[ "$ran" == "true" ]]; then
    return 0
  fi
  return 2
}

PLAN_FILE=""
RUN_WORKFLOW_TESTS="${VERIFY_WORKFLOW_TESTS:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN_FILE="${2:-}"
      if [[ -z "$PLAN_FILE" ]]; then
        echo "Usage: $0 --plan <plan-file>" >&2
        exit 1
      fi
      shift 2
      ;;
    --workflow)
      RUN_WORKFLOW_TESTS=1
      shift
      ;;
    *)
      echo "Usage: $0 [--plan <plan-file>] [--workflow]" >&2
      exit 1
      ;;
  esac
done
export PLAN_FILE

if [[ -n "$PLAN_FILE" ]]; then
  set +e
  run_plan_verify "$PLAN_FILE"
  plan_status=$?
  set -e
  if [[ "$plan_status" -eq 0 ]]; then
    run_default_verify
  elif [[ "$plan_status" -eq 2 ]]; then
    run_default_verify
  else
    exit "$plan_status"
  fi
elif [[ "$RUN_WORKFLOW_TESTS" == "1" || "$RUN_WORKFLOW_TESTS" == "true" ]]; then
  run_workflow_verify
else
  run_default_verify
fi

echo "==> verify: OK"
