#!/usr/bin/env bash
# Shared Python environment for OpenCode agent work and wrapper verification.

agent_python_env_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s' "$REPO_ROOT"
    return
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

agent_python_env_venv() {
  if [[ -n "${AGENT_PYTHON_VENV:-}" ]]; then
    printf '%s' "$AGENT_PYTHON_VENV"
    return
  fi
  if [[ -n "${AGENT_MACHINE_DIR:-}" ]]; then
    printf '%s' "${AGENT_MACHINE_DIR}/venv"
    return
  fi
  printf '%s' "$(agent_python_env_root)/machine/venv"
}

agent_python_env_activate() {
  local venv
  [[ "${AGENT_SKIP_PYTHON_ENV:-}" != "1" ]] || return 0
  venv="$(agent_python_env_venv)"
  if [[ -f "${venv}/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "${venv}/bin/activate"
  fi
}

agent_python_env_install() {
  local root venv
  root="$(agent_python_env_root)"
  venv="$(agent_python_env_venv)"

  if [[ ! -d "$venv" ]]; then
    python3 -m venv "$venv"
  fi

  # shellcheck source=/dev/null
  source "${venv}/bin/activate"
  python -m pip install --upgrade pip
  if [[ -s "${root}/requirements.txt" ]]; then
    python -m pip install -r "${root}/requirements.txt"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  command="${1:-install}"
  case "$command" in
    install)
      agent_python_env_install
      ;;
    activate)
      agent_python_env_activate
      ;;
    path)
      agent_python_env_venv
      printf '\n'
      ;;
    *)
      echo "Usage: $0 [install|activate|path]" >&2
      exit 1
      ;;
  esac
fi
