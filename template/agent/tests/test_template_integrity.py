#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER_ROOT = ROOT.parent if (ROOT.parent / "autopilot_repo.py").is_file() else ROOT


def load_installer():
    path = INSTALLER_ROOT / "autopilot_repo.py"
    spec = importlib.util.spec_from_file_location("installer", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class TemplateIntegrityTest(unittest.TestCase):
    def test_template_has_no_regulations_test3_runtime_defaults(self):
        allowed = {
            "agent/tests/test_template_integrity.py",
            "agent/tests/test_checkpoint_restore.sh",
            "agent/tests/test_blocked_command_retry.sh",
        }
        needles = [
            "Boaoz/regulations-test3",
            "/home/boao/regulations-test3",
            "chenlin04-agent-regulations-test3",
            "agent-regulations-test3",
        ]
        for path in ROOT.rglob("*"):
            rel = path.relative_to(ROOT).as_posix()
            if "__pycache__" in path.parts:
                continue
            if not path.is_file() or rel in allowed:
                continue
            text = path.read_text(errors="ignore")
            for needle in needles:
                self.assertNotIn(needle, text, f"{needle} in {rel}")

    def test_installer_manifest_excludes_issue_artifacts_and_includes_wrappers(self):
        installer = load_installer()
        rels = set(installer.template_files(ROOT))
        self.assertIn("agent/scripts/bin/agent-gh", rels)
        self.assertIn("agent/scripts/bin/agent-git", rels)
        self.assertIn(".github/workflows/agent-goal.yml", rels)
        self.assertIn(".github/ISSUE_TEMPLATE/agent_inspect.yml", rels)
        self.assertNotIn("autopilot_repo.py", rels)
        self.assertNotIn("README.md", rels)
        self.assertNotIn("agent-workflow-replication-guide.md", rels)
        self.assertTrue(all(not rel.startswith("src/issue-") for rel in rels))
        self.assertTrue(all(not rel.startswith("res/issue-") for rel in rels))
        self.assertTrue(all(not rel.startswith("knowledge/issue-") for rel in rels))
        self.assertTrue(all(not rel.startswith("machine/") for rel in rels))
        self.assertIn("credentials/github_agent.txt", rels)
        self.assertNotIn("credentials/agent_clickhouse_login.txt", rels)
        self.assertNotIn(".codex/config.toml", rels)
        self.assertTrue(all(not rel.startswith(".git/") for rel in rels))

    def test_root_keeps_installer_and_payload_lives_under_template(self):
        self.assertTrue((INSTALLER_ROOT / "autopilot_repo.py").is_file())
        self.assertTrue((INSTALLER_ROOT / "README.md").is_file())
        self.assertTrue((INSTALLER_ROOT / "requirements.txt").is_file())
        self.assertTrue((INSTALLER_ROOT / "template" / "AGENTS.md").is_file())
        self.assertFalse((INSTALLER_ROOT / "template" / ".codex").exists())
        self.assertFalse((INSTALLER_ROOT / "AGENTS.md").exists())
        self.assertFalse((INSTALLER_ROOT / "agent-workflow-replication-guide.md").exists())
        self.assertFalse((ROOT / "agent-workflow-replication-guide.md").exists())

    def test_root_requirements_are_not_copied_into_targets(self):
        installer = load_installer()
        self.assertEqual(
            (INSTALLER_ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines(),
            ["git", "gh", "bash", "python3", "curl", "screen", "opencode"],
        )
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"

            installer.copy_relevant_files_to_target(ROOT, local_dir)

            self.assertEqual(
                (local_dir / "requirements.txt").read_text(encoding="utf-8"),
                (ROOT / "requirements.txt").read_text(encoding="utf-8"),
            )
            self.assertNotEqual(
                (local_dir / "requirements.txt").read_text(encoding="utf-8"),
                (INSTALLER_ROOT / "requirements.txt").read_text(encoding="utf-8"),
            )

    def test_default_template_dir_points_to_payload_subdirectory(self):
        installer = load_installer()
        args = installer.parse_args([
            "prepare",
            "--repo-url",
            "example/project",
            "--local-dir",
            "/tmp/project",
        ])
        self.assertEqual(args.template_dir, INSTALLER_ROOT / "template")

    def test_shutdown_does_not_require_repo_url(self):
        installer = load_installer()
        args = installer.parse_args([
            "shutdown",
            "--local-dir",
            "/tmp/project",
        ])

        self.assertEqual(args.stage, "shutdown")
        self.assertIsNone(args.repo_url)

    def test_resume_does_not_require_repo_url(self):
        installer = load_installer()
        args = installer.parse_args([
            "resume",
            "--local-dir",
            "/tmp/project",
        ])

        self.assertEqual(args.stage, "resume")
        self.assertIsNone(args.repo_url)

    def test_shutdown_stops_both_runner_profiles_without_credentials(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            stop_script = local_dir / "agent/setup/stop-github-runner.sh"
            stop_script.parent.mkdir(parents=True)
            stop_script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            seen = []

            def fake_run(command, cwd=None, dry_run=False, env=None):
                seen.append((command, cwd, dry_run, env))

            installer.run = fake_run
            installer.shutdown(local_dir)

            self.assertEqual(
                [item[0] for item in seen],
                [[str(stop_script)], [str(stop_script), "--inspect"]],
            )
            self.assertTrue(all(item[1] == local_dir for item in seen))
            self.assertTrue(all(item[3]["AGENT_PROJECT_ROOT"] == str(local_dir) for item in seen))

    def test_resume_starts_both_runner_profiles_from_origin(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            start_script = local_dir / "agent/setup/start-github-runner.sh"
            start_script.parent.mkdir(parents=True)
            start_script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            (local_dir / ".git").mkdir()
            seen = []

            def fake_output(command, cwd=None, env=None):
                self.assertEqual(command, ["git", "remote", "get-url", "origin"])
                self.assertEqual(cwd, local_dir)
                return "https://github.com/example/project.git"

            def fake_run(command, cwd=None, dry_run=False, env=None):
                seen.append((command, cwd, dry_run, env))

            installer.output = fake_output
            installer.run = fake_run
            installer.resume(local_dir)

            self.assertEqual(
                [item[0] for item in seen],
                [
                    [str(start_script), "example/project"],
                    [str(start_script), "example/project", "--inspect"],
                ],
            )
            self.assertTrue(all(item[1] == local_dir for item in seen))
            self.assertTrue(all(item[3]["GITHUB_REPOSITORY"] == "example/project" for item in seen))

    def test_default_opencode_profile_is_gpt_5_6_sol_medium(self):
        installer = load_installer()
        config = (ROOT / "agent/opencode-profile.json").read_text(encoding="utf-8")

        self.assertEqual(installer.DEFAULT_MODEL, "openai/gpt-5.6-sol")
        self.assertEqual(installer.DEFAULT_REASONING_EFFORT, "medium")
        self.assertIn('"model": "openai/gpt-5.6-sol"', config)
        self.assertIn('"variant": "medium"', config)

    def test_opencode_wrapper_explicitly_applies_project_profile(self):
        wrapper = (ROOT / "agent/scripts/agent-opencode-exec.sh").read_text(encoding="utf-8")

        self.assertIn('config_file="$execution_root/agent/opencode-profile.json"', wrapper)
        self.assertIn('opencode run', wrapper)
        self.assertIn('--agent autopilot', wrapper)
        self.assertIn('--model "${project_profile[0]}"', wrapper)
        self.assertIn('--variant "${project_profile[1]}"', wrapper)
        self.assertIn('--auto', wrapper)

    def test_completed_and_fix_runs_clear_checkpoints(self):
        goal_runner = (ROOT / "agent/scripts/run-agent-goal.sh").read_text(encoding="utf-8")
        knowledge_runner = (ROOT / "agent/scripts/run-agent-knowledge.sh").read_text(encoding="utf-8")
        prepare = (ROOT / "agent/scripts/agent-prepare-workspace.sh").read_text(encoding="utf-8")

        self.assertGreaterEqual(goal_runner.count('clear_agent_checkpoint "$ISSUE"'), 2)
        self.assertGreaterEqual(knowledge_runner.count('clear_agent_checkpoint "$ISSUE"'), 2)
        self.assertIn("fix)\n    clear_agent_checkpoint", prepare)

    def test_model_arguments_accept_repo_preferences(self):
        installer = load_installer()
        args = installer.parse_args([
            "prepare",
            "--repo-url",
            "example/project",
            "--local-dir",
            "/tmp/project",
            "--model",
            "xai/grok-build-0.1",
            "--reasoning",
            "high",
        ])

        self.assertEqual(args.model, "xai/grok-build-0.1")
        self.assertEqual(args.reasoning, "high")

    def test_model_requires_exact_provider_model_id(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            installer.copy_template(ROOT, local_dir)

            with self.assertRaisesRegex(SystemExit, "exact OpenCode provider/model ID"):
                installer.configure_model(local_dir, "grok")

            with self.assertRaisesRegex(SystemExit, "exact OpenCode provider/model ID"):
                installer.prepare_target_files(
                    "example/project",
                    local_dir,
                    ROOT,
                    dry_run=True,
                    model="grok",
                )

    def test_reasoning_arguments_match_opencode_variants(self):
        installer = load_installer()

        self.assertEqual(
            installer.REASONING_EFFORTS,
            ("low", "medium", "high", "xhigh", "max", "ultra"),
        )
        for reasoning in installer.REASONING_EFFORTS:
            args = installer.parse_args([
                "prepare",
                "--repo-url",
                "example/project",
                "--local-dir",
                "/tmp/project",
                "--reasoning",
                reasoning,
            ])
            self.assertEqual(args.reasoning, reasoning)

    def test_framework_files_live_under_agent_directory(self):
        rels = {path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*") if path.is_file()}
        self.assertIn("agent/scripts/agent-goal-orchestrator.sh", rels)
        self.assertIn("agent/setup/setup-once.sh", rels)
        self.assertIn("agent/tests/test_verify_plan_failures.sh", rels)
        self.assertIn("agent/scripts/bin/agent-gh", rels)
        self.assertNotIn("scripts/agent-goal-orchestrator.sh", rels)
        self.assertNotIn("setup/setup-once.sh", rels)
        self.assertNotIn("tests/test_verify_plan_failures.sh", rels)

    def test_repo_slug_parser_accepts_common_github_urls(self):
        installer = load_installer()
        self.assertEqual(installer.repo_slug("https://github.com/example/project.git"), "example/project")
        self.assertEqual(installer.repo_slug("git@github.com:example/project.git"), "example/project")
        self.assertEqual(installer.repo_slug("example/project"), "example/project")

    def test_install_commands_use_agent_wrappers_not_global_gh(self):
        installer = load_installer()
        commands = installer.planned_commands(
            repo_url="https://github.com/example/project.git",
            local_dir=pathlib.Path("/tmp/project"),
            template_dir=ROOT,
        )
        command_text = "\n".join(" ".join(command) for command in commands)
        self.assertIn("/tmp/project/agent/scripts/bin/agent-gh", command_text)
        self.assertIn("/tmp/project/agent/scripts/bin/agent-git", command_text)
        self.assertIn("/tmp/project/agent/scripts/agent-python-env.sh install", command_text)
        self.assertIn("setup-github-runner.sh example/project --inspect", command_text)
        self.assertIn("start-github-runner.sh example/project --inspect", command_text)
        for command in commands:
            self.assertNotEqual(pathlib.Path(command[0]).name, "gh")
            self.assertNotEqual(pathlib.Path(command[0]).name, "git")

    def test_prepare_target_files_creates_runtime_credential_skeleton(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"

            copied = installer.copy_relevant_files_to_target(ROOT, local_dir)

            credential_path = local_dir / "credentials/github_agent.txt"
            self.assertIn("credentials/github_agent.txt", copied)
            self.assertTrue(credential_path.exists())
            self.assertEqual(
                credential_path.read_text(encoding="utf-8"),
                '{\n  "username": "YOUR_AGENT_GITHUB_USERNAME",\n'
                '  "access_token": "YOUR_AGENT_GITHUB_ACCESS_TOKEN"\n}\n',
            )
            self.assertEqual(credential_path.stat().st_mode & 0o777, 0o600)

    def test_prepare_preserves_existing_runtime_credentials(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            credential_path = local_dir / "credentials/github_agent.txt"
            credential_path.parent.mkdir(parents=True)
            configured = '{"username":"research-agent","access_token":"secret"}\n'
            credential_path.write_text(configured, encoding="utf-8")

            installer.copy_relevant_files_to_target(ROOT, local_dir)

            self.assertEqual(credential_path.read_text(encoding="utf-8"), configured)
            self.assertEqual(credential_path.stat().st_mode & 0o777, 0o600)

    def test_prepare_dry_run_does_not_modify_existing_checkout(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            local_dir.mkdir()
            (local_dir / ".git").mkdir()
            sentinel = local_dir / "README.md"
            sentinel.write_text("keep me\n", encoding="utf-8")

            installer.prepare_target_files(
                "example/project",
                local_dir,
                ROOT,
                dry_run=True,
            )

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep me\n")
            self.assertFalse((local_dir / "agent").exists())

    def test_make_live_dry_run_does_not_require_credentials_or_copy_files(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            local_dir.mkdir()
            (local_dir / ".git").mkdir()
            sentinel = local_dir / "README.md"
            sentinel.write_text("keep me\n", encoding="utf-8")

            installer.make_everything_live(
                "example/project",
                local_dir,
                ROOT,
                dry_run=True,
            )

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep me\n")
            self.assertFalse((local_dir / "agent").exists())

    def test_copy_configures_selected_model(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"

            installer.copy_relevant_files_to_target(
                ROOT,
                local_dir,
                model="xai/grok-build-0.1",
                reasoning_effort="high",
            )

            self.assertEqual(installer.read_configured_model(local_dir), "xai/grok-build-0.1")
            self.assertEqual(installer.read_configured_reasoning_effort(local_dir), "high")
            config = (local_dir / "agent/opencode-profile.json").read_text(encoding="utf-8")
            self.assertIn('"variant": "high"', config)

    def test_existing_repo_model_can_be_preserved_during_make_live(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            (local_dir / "agent").mkdir(parents=True)
            (local_dir / "agent/opencode-profile.json").write_text(
                '{"model": "provider/preferred-model", "variant": "medium"}\n',
                encoding="utf-8",
            )

            selected_model = installer.read_configured_model(local_dir) or installer.DEFAULT_MODEL
            selected_reasoning_effort = (
                installer.read_configured_reasoning_effort(local_dir)
                or installer.DEFAULT_REASONING_EFFORT
            )
            installer.copy_relevant_files_to_target(
                ROOT,
                local_dir,
                selected_model,
                selected_reasoning_effort,
            )

            self.assertEqual(installer.read_configured_model(local_dir), "provider/preferred-model")
            self.assertEqual(installer.read_configured_reasoning_effort(local_dir), "medium")

    def test_stage_commands_force_only_ignored_placeholders(self):
        installer = load_installer()
        commands = installer.stage_commands(
            agent_git=pathlib.Path("/tmp/project/agent/scripts/bin/agent-git"),
            copied=["README.md", "credentials/.gitkeep", "credentials/github_agent.txt", "machine/.gitkeep"],
        )
        self.assertIn("README.md", commands[0])
        self.assertIn(["/tmp/project/agent/scripts/bin/agent-git", "add", "-f", "credentials/.gitkeep", "machine/.gitkeep"], commands)
        self.assertNotIn("credentials/github_agent.txt", "\n".join(" ".join(command) for command in commands))

    def test_has_changes_uses_target_install_environment(self):
        installer = load_installer()
        seen = {}

        def fake_output(command, cwd=None, env=None):
            seen["command"] = command
            seen["cwd"] = cwd
            seen["env"] = env
            return ""

        installer.output = fake_output
        env = {
            "AGENT_PROJECT_ROOT": "/tmp/new-project",
            "AGENT_GITHUB_CREDENTIALS": "/tmp/new-project/credentials/github_agent.txt",
        }

        self.assertFalse(installer.has_changes(pathlib.Path("/tmp/new-project/agent/scripts/bin/agent-git"), pathlib.Path("/tmp/new-project"), env))
        self.assertIs(seen["env"], env)
        self.assertEqual(seen["env"]["AGENT_GITHUB_CREDENTIALS"], "/tmp/new-project/credentials/github_agent.txt")

    def test_template_readme_installs_as_top_level_readme(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            template_dir = pathlib.Path(tmp) / "template"
            local_dir = pathlib.Path(tmp) / "target"
            template_dir.mkdir()
            (template_dir / "README.md").write_text("# Default\n", encoding="utf-8")

            copied = installer.copy_default_readme(template_dir, local_dir)

            self.assertEqual(copied, "README.md")
            self.assertEqual((local_dir / "README.md").read_text(encoding="utf-8"), "# Default\n")

    def test_live_setup_requires_human_filled_target_credentials(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "target"
            template_dir = pathlib.Path(tmp) / "template"
            (local_dir / "credentials").mkdir(parents=True)
            (template_dir / "credentials").mkdir(parents=True)
            target = local_dir / "credentials/github_agent.txt"
            target.write_text(
                '{"username":"YOUR_AGENT_GITHUB_USERNAME",'
                '"access_token":"YOUR_AGENT_GITHUB_ACCESS_TOKEN"}\n',
                encoding="utf-8",
            )

            with self.assertRaises(SystemExit):
                installer.resolve_agent_credentials(local_dir, template_dir, {})

            target.write_text('{"username":"research-agent","access_token":"fake"}\n', encoding="utf-8")
            self.assertEqual(installer.resolve_agent_credentials(local_dir, template_dir, {}), target)

    def test_build_install_env_overrides_stale_agent_project_paths_and_uses_credential_username(self):
        installer = load_installer()
        with tempfile.TemporaryDirectory() as tmp:
            local_dir = pathlib.Path(tmp) / "new-project"
            template_dir = pathlib.Path(tmp) / "template"
            (local_dir / "credentials").mkdir(parents=True)
            (template_dir / "credentials").mkdir(parents=True)
            credential = local_dir / "credentials/github_agent.txt"
            credential.write_text('{"username":"research-agent","access_token":"fake"}\n', encoding="utf-8")
            base_env = {
                "AGENT_PROJECT_ROOT": "/tmp/old-project",
                "AGENT_REPO_ROOT": "/tmp/old-project",
                "AGENT_MACHINE_DIR": "/tmp/old-project/machine",
                "AGENT_RUNS_DIR": "/tmp/old-project/machine/runs",
                "AGENT_RUNNER_DIR": "/tmp/old-project/machine/runner/github-actions",
                "AGENT_RUNNER_LOG": "/tmp/old-project/machine/logs/runner.log",
                "AGENT_RUNNER_SCREEN": "agent-old-project-runner",
                "AGENT_INSPECT_RUNNER_DIR": "/tmp/old-project/machine/runner/github-actions-inspect",
                "AGENT_INSPECT_RUNNER_LOG": "/tmp/old-project/machine/logs/runner-inspect.log",
                "AGENT_INSPECT_RUNNER_SCREEN": "agent-old-project-inspect-runner",
                "AGENT_GITHUB_CREDENTIALS": "/tmp/old-project/credentials/github_agent.txt",
            }

            env = installer.build_install_env(
                slug="example/new-project",
                local_dir=local_dir,
                template_dir=template_dir,
                base_env=base_env,
            )

            self.assertEqual(env["GITHUB_REPOSITORY"], "example/new-project")
            self.assertEqual(env["AGENT_PROJECT_ROOT"], str(local_dir))
            self.assertEqual(env["AGENT_REPO_ROOT"], str(local_dir))
            self.assertEqual(env["AGENT_MACHINE_DIR"], str(local_dir / "machine"))
            self.assertEqual(env["AGENT_RUNS_DIR"], str(local_dir / "machine/runs"))
            self.assertEqual(env["AGENT_RUNNER_DIR"], str(local_dir / "machine/runner/github-actions"))
            self.assertEqual(env["AGENT_RUNNER_LOG"], str(local_dir / "machine/logs/runner.log"))
            self.assertEqual(env["AGENT_RUNNER_SCREEN"], "agent-new-project-runner")
            self.assertEqual(env["AGENT_INSPECT_RUNNER_DIR"], str(local_dir / "machine/runner/github-actions-inspect"))
            self.assertEqual(env["AGENT_INSPECT_RUNNER_LOG"], str(local_dir / "machine/logs/runner-inspect.log"))
            self.assertEqual(env["AGENT_INSPECT_RUNNER_SCREEN"], "agent-new-project-inspect-runner")
            self.assertEqual(env["AGENT_GITHUB_USERNAME"], "research-agent")
            self.assertEqual(env["AGENT_GITHUB_CREDENTIALS"], str(credential))

    def test_runner_setup_requires_admin_permission(self):
        installer = load_installer()
        with self.assertRaises(SystemExit):
            installer.require_runner_admin_permission({"admin": False, "push": True})
        installer.require_runner_admin_permission({"admin": True, "push": True})


if __name__ == "__main__":
    unittest.main()
