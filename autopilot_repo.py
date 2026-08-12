#!/usr/bin/env python3
"""Install the generic agent workflow template into a GitHub repository checkout."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Iterable


EXCLUDE_DIR_NAMES = {".git", ".pytest_cache", "__pycache__"}
EXCLUDE_PREFIXES = (
    "src/issue-",
    "res/issue-",
    "knowledge/issue-",
    "machine/",
    "credentials/",
)
INCLUDE_CREDENTIAL_PLACEHOLDER = "credentials/.gitkeep"
TEMPLATE_ONLY_FILES = {
    "autopilot_repo.py",
    "README.md",
}
DEFAULT_README_TEMPLATE = "README.md"
DEFAULT_AGENT_CREDENTIAL = "credentials/github_agent.txt"
DEFAULT_CLICKHOUSE_CREDENTIAL = "credentials/agent_clickhouse_login.txt"
DEFAULT_AGENT_CREDENTIALS = {
    "username": "YOUR_AGENT_GITHUB_USERNAME",
    "access_token": "YOUR_AGENT_GITHUB_ACCESS_TOKEN",
}
DEFAULT_MODEL = "openai/gpt-5.6-sol"
DEFAULT_REASONING_EFFORT = "medium"
REASONING_EFFORTS = ("low", "medium", "high", "xhigh", "max", "ultra")
OPENCODE_PROFILE = "agent/opencode-profile.json"


def default_template_dir() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent / "template"


def repo_slug(repo_url: str) -> str:
    value = repo_url.strip()
    match = re.fullmatch(r"https://github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?", value)
    if match:
        return match.group(1)
    match = re.fullmatch(r"git@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?", value)
    if match:
        return match.group(1)
    if re.fullmatch(r"[^:@/\s]+/[^/\s]+", value):
        return value.removesuffix(".git")
    raise ValueError(f"Unsupported GitHub repo URL: {repo_url}")


def normalize_repo_url(repo_url: str) -> str:
    slug = repo_slug(repo_url)
    return f"https://github.com/{slug}.git"


def should_copy(rel: str) -> bool:
    if rel in {INCLUDE_CREDENTIAL_PLACEHOLDER, DEFAULT_AGENT_CREDENTIAL}:
        return True
    if rel in TEMPLATE_ONLY_FILES:
        return False
    parts = pathlib.PurePosixPath(rel).parts
    if any(part in EXCLUDE_DIR_NAMES for part in parts):
        return False
    return not any(rel.startswith(prefix) for prefix in EXCLUDE_PREFIXES)


def template_files(template_dir: pathlib.Path) -> list[str]:
    files: list[str] = []
    for path in template_dir.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(template_dir).as_posix()
        if should_copy(rel):
            files.append(rel)
    return sorted(files)


def copy_template(template_dir: pathlib.Path, local_dir: pathlib.Path) -> list[str]:
    copied: list[str] = []
    for rel in template_files(template_dir):
        src = template_dir / rel
        dst = local_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if rel == DEFAULT_AGENT_CREDENTIAL and dst.exists():
            dst.chmod(0o600)
        else:
            shutil.copy2(src, dst)
            if rel == DEFAULT_AGENT_CREDENTIAL:
                dst.chmod(0o600)
        copied.append(rel)
    for dirname in ("src", "res", "knowledge", "credentials", "machine"):
        directory = local_dir / dirname
        directory.mkdir(parents=True, exist_ok=True)
        keep = directory / ".gitkeep"
        if not keep.exists():
            keep.touch()
    return copied


def copy_default_readme(template_dir: pathlib.Path, local_dir: pathlib.Path) -> str | None:
    source = template_dir / DEFAULT_README_TEMPLATE
    if not source.is_file():
        return None
    target = local_dir / "README.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return "README.md"


def _validate_model_id(model: str, option: str = "--model") -> str:
    model = model.strip()
    if not model or "\n" in model or "\r" in model:
        raise SystemExit(f"{option} must be a non-empty, single-line model name")
    if "/" not in model or model.startswith("/") or model.endswith("/"):
        raise SystemExit(
            f"{option} must be an exact OpenCode provider/model ID "
            f"(for example openai/gpt-5.6-sol or xai/grok-4.5)"
        )
    return model


def read_configured_model(local_dir: pathlib.Path) -> str | None:
    config_path = local_dir / OPENCODE_PROFILE
    if not config_path.is_file():
        return None
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    model = data.get("model")
    return model if isinstance(model, str) and model else None


def read_configured_reasoning_effort(local_dir: pathlib.Path) -> str | None:
    config_path = local_dir / OPENCODE_PROFILE
    if not config_path.is_file():
        return None
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    variant = data.get("variant")
    return variant if isinstance(variant, str) and variant else None


def configure_model(local_dir: pathlib.Path, model: str, reasoning_effort: str = DEFAULT_REASONING_EFFORT) -> None:
    model = _validate_model_id(model)
    if reasoning_effort not in REASONING_EFFORTS:
        choices = ", ".join(REASONING_EFFORTS)
        raise SystemExit(f"--reasoning must be one of: {choices}")
    config_path = local_dir / OPENCODE_PROFILE
    if not config_path.is_file():
        raise SystemExit(f"Template copy did not create {OPENCODE_PROFILE}")
    config_path.write_text(
        json.dumps({"model": model, "variant": reasoning_effort}, indent=2) + "\n",
        encoding="utf-8",
    )


def copy_relevant_files_to_target(
    template_dir: pathlib.Path,
    local_dir: pathlib.Path,
    model: str = DEFAULT_MODEL,
    reasoning_effort: str = DEFAULT_REASONING_EFFORT,
) -> list[str]:
    copied = copy_template(template_dir, local_dir)
    configure_model(local_dir, model, reasoning_effort)
    default_readme = copy_default_readme(template_dir, local_dir)
    if default_readme is not None:
        copied.append(default_readme)
    return copied


def run(command: list[str], cwd: pathlib.Path | None = None, dry_run: bool = False, env: dict[str, str] | None = None) -> None:
    if dry_run:
        print("+", " ".join(command))
        return
    subprocess.run(command, cwd=cwd, env=env, check=True)


def output(command: list[str], cwd: pathlib.Path | None = None, env: dict[str, str] | None = None) -> str:
    return subprocess.check_output(command, cwd=cwd, env=env, text=True).strip()


def resolve_agent_credentials(local_dir: pathlib.Path, template_dir: pathlib.Path, env: dict[str, str]) -> pathlib.Path:
    candidates = []
    if env.get("AGENT_GITHUB_CREDENTIALS"):
        candidates.append(pathlib.Path(env["AGENT_GITHUB_CREDENTIALS"]))
    candidates.append(local_dir / DEFAULT_AGENT_CREDENTIAL)
    for candidate in candidates:
        if not candidate.is_file() or candidate.stat().st_size == 0:
            continue
        try:
            credentials = json.loads(candidate.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        username = str(credentials.get("username", "")).strip()
        access_token = str(credentials.get("access_token", "")).strip()
        if (
            username
            and access_token
            and username != DEFAULT_AGENT_CREDENTIALS["username"]
            and access_token != DEFAULT_AGENT_CREDENTIALS["access_token"]
        ):
            return candidate
    raise SystemExit(
        "Missing agent credentials. Fill credentials/github_agent.txt "
        "in the target checkout, or set AGENT_GITHUB_CREDENTIALS to a non-empty credential file."
    )


def read_agent_username(credential_path: pathlib.Path) -> str:
    with credential_path.open(encoding="utf-8") as fh:
        credentials = json.load(fh)
    username = str(credentials.get("username", "")).strip()
    if not username:
        raise SystemExit(f"Credential file is missing username: {credential_path}")
    return username


def build_install_env(
    slug: str,
    local_dir: pathlib.Path,
    template_dir: pathlib.Path,
    base_env: dict[str, str] | None = None,
) -> dict[str, str]:
    env = dict(base_env or os.environ)
    env["GITHUB_REPOSITORY"] = slug
    env["AGENT_PROJECT_ROOT"] = str(local_dir)
    env["AGENT_REPO_ROOT"] = str(local_dir)
    env["AGENT_MACHINE_DIR"] = str(local_dir / "machine")
    env["AGENT_RUNS_DIR"] = str(local_dir / "machine/runs")
    env["AGENT_RUNNER_DIR"] = str(local_dir / "machine/runner/github-actions")
    env["AGENT_RUNNER_LOG"] = str(local_dir / "machine/logs/runner.log")
    env["AGENT_INSPECT_RUNNER_DIR"] = str(local_dir / "machine/runner/github-actions-inspect")
    env["AGENT_INSPECT_RUNNER_LOG"] = str(local_dir / "machine/logs/runner-inspect.log")
    repo_slug_text = re.sub(r"[^A-Za-z0-9_.-]+", "-", local_dir.name)
    credential_path = resolve_agent_credentials(local_dir, template_dir, env)
    username = read_agent_username(credential_path)
    # Screen sessions are scoped to the checkout, not the credential account.
    env["AGENT_RUNNER_SCREEN"] = f"agent-{repo_slug_text}-runner"
    env["AGENT_INSPECT_RUNNER_SCREEN"] = f"agent-{repo_slug_text}-inspect-runner"
    env["AGENT_GITHUB_CREDENTIALS"] = str(credential_path)
    env["AGENT_GITHUB_USERNAME"] = username
    return env


def planned_commands(repo_url: str, local_dir: pathlib.Path, template_dir: pathlib.Path) -> list[list[str]]:
    slug = repo_slug(repo_url)
    agent_gh = str(local_dir / "agent/scripts/bin/agent-gh")
    agent_git = str(local_dir / "agent/scripts/bin/agent-git")
    return [
        [agent_gh, "api", "user/repository_invitations"],
        [agent_gh, "api", f"repos/{slug}"],
        [agent_git, "remote", "set-url", "origin", normalize_repo_url(repo_url)],
        [agent_git, "push", "-u", "origin", "main"],
        [str(local_dir / "agent/scripts/agent-python-env.sh"), "install"],
        [str(local_dir / "agent/setup/setup-github-labels.sh"), slug],
        [str(local_dir / "agent/setup/setup-github-runner.sh"), slug],
        [str(local_dir / "agent/setup/start-github-runner.sh"), slug],
        [str(local_dir / "agent/setup/setup-github-runner.sh"), slug, "--inspect"],
        [str(local_dir / "agent/setup/start-github-runner.sh"), slug, "--inspect"],
    ]


def require_runner_admin_permission(permissions: dict[str, object]) -> None:
    if permissions.get("admin") is True:
        return
    raise SystemExit(
        "The configured agent can push to this repository but cannot register a self-hosted "
        "runner. Grant the agent account Admin permission for this repo, then rerun the "
        "installer or run agent/setup/setup-github-runner.sh and agent/setup/start-github-runner.sh."
    )


def ensure_checkout(repo_url: str, local_dir: pathlib.Path, dry_run: bool) -> None:
    if local_dir.exists() and (local_dir / ".git").exists():
        return
    if local_dir.exists() and any(local_dir.iterdir()):
        raise SystemExit(f"{local_dir} exists but is not a git checkout")
    if not dry_run:
        local_dir.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", normalize_repo_url(repo_url), str(local_dir)], dry_run=dry_run)


def accept_invitation(agent_gh: pathlib.Path, slug: str, cwd: pathlib.Path, dry_run: bool, env: dict[str, str]) -> None:
    if dry_run:
        print("+", str(agent_gh), "api user/repository_invitations")
        print("+", str(agent_gh), "api -X PATCH user/repository_invitations/<id>")
        return
    invitations = output([str(agent_gh), "api", "user/repository_invitations", "--jq", f'.[] | select(.repository.full_name == "{slug}") | .id'], cwd=cwd, env=env)
    invitation_id = invitations.splitlines()[0] if invitations else ""
    if invitation_id:
        run([str(agent_gh), "api", "-X", "PATCH", f"user/repository_invitations/{invitation_id}"], cwd=cwd, env=env)
        return
    run([str(agent_gh), "api", f"repos/{slug}"], cwd=cwd, env=env)


def repo_permissions(agent_gh: pathlib.Path, slug: str, cwd: pathlib.Path, env: dict[str, str]) -> dict[str, object]:
    raw = output([str(agent_gh), "api", f"repos/{slug}", "--jq", ".permissions"], cwd=cwd, env=env)
    return json.loads(raw)


def has_changes(agent_git: pathlib.Path, cwd: pathlib.Path, env: dict[str, str]) -> bool:
    status = output([str(agent_git), "status", "--porcelain"], cwd=cwd, env=env)
    return bool(status)


def stage_commands(agent_git: pathlib.Path, copied: list[str]) -> list[list[str]]:
    ignored_placeholders = ["credentials/.gitkeep", "machine/.gitkeep"]
    never_stage = {DEFAULT_AGENT_CREDENTIAL, DEFAULT_CLICKHOUSE_CREDENTIAL}
    normal_files = sorted(
        set(copied + ["src/.gitkeep", "res/.gitkeep", "knowledge/.gitkeep"])
        - set(ignored_placeholders)
        - never_stage
    )
    return [
        [str(agent_git), "add", *normal_files],
        [str(agent_git), "add", "-f", *ignored_placeholders],
    ]


def prepare_target_files(
    repo_url: str,
    local_dir: pathlib.Path,
    template_dir: pathlib.Path,
    dry_run: bool = False,
    model: str = DEFAULT_MODEL,
    reasoning_effort: str = DEFAULT_REASONING_EFFORT,
) -> None:
    model = _validate_model_id(model)
    if reasoning_effort not in REASONING_EFFORTS:
        choices = ", ".join(REASONING_EFFORTS)
        raise SystemExit(f"--reasoning must be one of: {choices}")
    ensure_checkout(repo_url, local_dir, dry_run)
    if dry_run:
        print("+", f"copy relevant template files into {local_dir}")
        print("+", f"create credential skeleton at {local_dir / DEFAULT_AGENT_CREDENTIAL}")
        print("+", f"configure {OPENCODE_PROFILE} with model={model} variant={reasoning_effort}")
        return
    copy_relevant_files_to_target(template_dir, local_dir, model, reasoning_effort)


def make_everything_live(
    repo_url: str,
    local_dir: pathlib.Path,
    template_dir: pathlib.Path,
    dry_run: bool = False,
    model: str | None = None,
    reasoning_effort: str | None = None,
) -> None:
    slug = repo_slug(repo_url)
    ensure_checkout(repo_url, local_dir, dry_run)
    if dry_run:
        print("+", f"refresh template files in {local_dir} while preserving configured credentials")
        for command in planned_commands(repo_url, local_dir, template_dir):
            print("+", " ".join(command))
        return

    selected_model = model or read_configured_model(local_dir) or DEFAULT_MODEL
    selected_reasoning_effort = (
        reasoning_effort
        or read_configured_reasoning_effort(local_dir)
        or DEFAULT_REASONING_EFFORT
    )
    copied = copy_relevant_files_to_target(
        template_dir,
        local_dir,
        selected_model,
        selected_reasoning_effort,
    )
    agent_gh = local_dir / "agent/scripts/bin/agent-gh"
    agent_git = local_dir / "agent/scripts/bin/agent-git"
    if not agent_gh.exists() or not agent_git.exists():
        raise SystemExit("Template copy did not create agent/scripts/bin/agent-gh and agent/scripts/bin/agent-git")

    env = build_install_env(slug, local_dir, template_dir)

    accept_invitation(agent_gh, slug, local_dir, dry_run, env)
    run([str(agent_git), "remote", "set-url", "origin", normalize_repo_url(repo_url)], cwd=local_dir, dry_run=dry_run, env=env)
    agent_username = env["AGENT_GITHUB_USERNAME"]
    run([str(agent_git), "config", "user.name", agent_username], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(agent_git), "config", "user.email", f"{agent_username}@users.noreply.github.com"], cwd=local_dir, dry_run=dry_run, env=env)
    for command in stage_commands(agent_git, copied):
        run(command, cwd=local_dir, dry_run=dry_run, env=env)
    if dry_run or has_changes(agent_git, local_dir, env):
        run([str(agent_git), "commit", "-m", "chore: install agent workflow"], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(agent_git), "branch", "-M", "main"], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(agent_git), "push", "-u", "origin", "main"], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(local_dir / "agent/scripts/agent-python-env.sh"), "install"], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(local_dir / "agent/setup/setup-github-labels.sh"), slug], cwd=local_dir, dry_run=dry_run, env=env)
    if not dry_run:
        require_runner_admin_permission(repo_permissions(agent_gh, slug, local_dir, env))
    run([str(local_dir / "agent/setup/setup-github-runner.sh"), slug], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(local_dir / "agent/setup/start-github-runner.sh"), slug], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(local_dir / "agent/setup/setup-github-runner.sh"), slug, "--inspect"], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(local_dir / "agent/setup/start-github-runner.sh"), slug, "--inspect"], cwd=local_dir, dry_run=dry_run, env=env)


def install(
    repo_url: str,
    local_dir: pathlib.Path,
    template_dir: pathlib.Path,
    dry_run: bool = False,
    model: str = DEFAULT_MODEL,
    reasoning_effort: str = DEFAULT_REASONING_EFFORT,
) -> None:
    prepare_target_files(repo_url, local_dir, template_dir, dry_run, model, reasoning_effort)
    make_everything_live(repo_url, local_dir, template_dir, dry_run, model, reasoning_effort)


def local_runner_env(local_dir: pathlib.Path) -> dict[str, str]:
    env = dict(os.environ)
    env["AGENT_PROJECT_ROOT"] = str(local_dir)
    env["AGENT_REPO_ROOT"] = str(local_dir)
    env["AGENT_MACHINE_DIR"] = str(local_dir / "machine")
    env["AGENT_RUNNER_DIR"] = str(local_dir / "machine/runner/github-actions")
    env["AGENT_INSPECT_RUNNER_DIR"] = str(local_dir / "machine/runner/github-actions-inspect")
    return env


def require_local_runner_script(local_dir: pathlib.Path, relative_path: str) -> pathlib.Path:
    if not local_dir.is_dir():
        raise SystemExit(f"Target checkout does not exist: {local_dir}")
    script = local_dir / relative_path
    if not script.is_file():
        raise SystemExit(f"Target checkout does not contain the runner script: {script}")
    return script


def shutdown(local_dir: pathlib.Path, dry_run: bool = False) -> None:
    stop_script = require_local_runner_script(local_dir, "agent/setup/stop-github-runner.sh")
    env = local_runner_env(local_dir)
    run([str(stop_script)], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(stop_script), "--inspect"], cwd=local_dir, dry_run=dry_run, env=env)


def resume(local_dir: pathlib.Path, dry_run: bool = False) -> None:
    start_script = require_local_runner_script(local_dir, "agent/setup/start-github-runner.sh")
    if not (local_dir / ".git").exists():
        raise SystemExit(f"Target checkout is not a git repository: {local_dir}")
    try:
        origin_url = output(["git", "remote", "get-url", "origin"], cwd=local_dir)
        slug = repo_slug(origin_url)
    except (subprocess.CalledProcessError, ValueError) as exc:
        raise SystemExit(f"Could not determine GitHub repository from {local_dir}/.git origin: {exc}") from exc

    env = local_runner_env(local_dir)
    env["GITHUB_REPOSITORY"] = slug
    run([str(start_script), slug], cwd=local_dir, dry_run=dry_run, env=env)
    run([str(start_script), slug, "--inspect"], cwd=local_dir, dry_run=dry_run, env=env)


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "stage",
        nargs="?",
        default="install",
        choices=("install", "prepare", "make-live", "shutdown", "resume"),
        help="install runs prepare and make-live; shutdown/resume stop or start both local runner processes",
    )
    parser.add_argument("--repo-url", help="GitHub repository URL or owner/repo (not needed for shutdown or resume)")
    parser.add_argument("--local-dir", required=True, type=pathlib.Path, help="Local checkout path for the target repo")
    parser.add_argument("--template-dir", type=pathlib.Path, default=default_template_dir())
    parser.add_argument(
        "--model",
        help=(
            f"OpenCode provider/model ID for this repo (default: {DEFAULT_MODEL}; "
            "make-live preserves the prepared choice)"
        ),
    )
    parser.add_argument(
        "--reasoning",
        choices=REASONING_EFFORTS,
        help=(
            f"OpenCode model variant for this repo (default: {DEFAULT_REASONING_EFFORT}; "
            "make-live preserves it)"
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(list(argv))
    if args.stage not in {"shutdown", "resume"} and not args.repo_url:
        parser.error("--repo-url is required unless stage is shutdown or resume")
    return args


def main(argv: Iterable[str] = sys.argv[1:]) -> int:
    args = parse_args(argv)
    local_dir = args.local_dir.resolve()
    template_dir = args.template_dir.resolve()
    if args.stage == "shutdown":
        shutdown(local_dir, args.dry_run)
    elif args.stage == "resume":
        resume(local_dir, args.dry_run)
    elif args.stage == "prepare":
        prepare_target_files(
            args.repo_url,
            local_dir,
            template_dir,
            args.dry_run,
            args.model or DEFAULT_MODEL,
            args.reasoning or DEFAULT_REASONING_EFFORT,
        )
    elif args.stage == "make-live":
        make_everything_live(
            args.repo_url,
            local_dir,
            template_dir,
            args.dry_run,
            args.model,
            args.reasoning,
        )
    else:
        install(
            args.repo_url,
            local_dir,
            template_dir,
            args.dry_run,
            args.model or DEFAULT_MODEL,
            args.reasoning or DEFAULT_REASONING_EFFORT,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
