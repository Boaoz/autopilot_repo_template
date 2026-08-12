# Machine-local setup

Scripts and workflows live in this repo. **Credentials**, **machine runtime**, and **agent run logs** stay outside git.

## Layout

```
target-repo/
├── credentials/                 # NOT in git — PAT and deploy keys (chmod 600)
├── machine/                     # NOT in git — runner, state, logs, lock
│   ├── runner/github-actions/
│   ├── runner/github-actions-inspect/
│   ├── venv/                    # local plain Python venv for agent package installs
│   ├── runs/                    # local-only agent logs, plans, scratch
│   ├── state/
│   ├── logs/runner.log
│   └── lock/
└── .                            # this repo (synced to GitHub)
    ├── src/                     # agent-goal implementation code
    ├── knowledge/                    # documentation and knowledge
    ├── res/                     # generated outputs from running agent code
    └── agent/scripts/bin/             # agent-gh, agent-git
```

## Credentials (required)

The template installer copies its `credentials/github_agent.txt` skeleton into
a new repository. Replace both placeholders, or set `AGENT_GITHUB_CREDENTIALS`
to another local credential path:

```json
{
  "username": "YOUR_AGENT_GITHUB_USERNAME",
  "access_token": "YOUR_AGENT_GITHUB_ACCESS_TOKEN"
}
```

```bash
chmod 600 credentials/github_agent.txt
```

Optional deploy keys also go in `credentials/`. Never commit real credentials.

Optional service credentials for agent-knowledge exploration:

```json
{"host": "...", "username": "...", "password": "...", "database": "federal_register_rules_n_regulations"}
```

Save as `credentials/agent_clickhouse_login.txt` if your project needs it.

```bash
chmod 600 credentials/agent_clickhouse_login.txt
```

## Self-hosted network access

Agent jobs run in a **screen** session on this host (`./agent/setup/start-github-runner.sh`).
OpenCode is invoked via `agent/scripts/agent-opencode-exec.sh` with automatic permission approval on
the trusted self-hosted runner. This preserves access to host GPUs, local
runtimes, project credentials, and outbound network resources. Do not store
unrelated secrets in locations readable by the runner user.

## OpenCode model

All agent workflows use repository-local `opencode.json` and
`agent/opencode-profile.json`. The default model is `openai/gpt-5.6-sol` with
the `medium` variant. Use installer `--model` and `--reasoning` options to
select an exact OpenCode provider/model ID and model variant. Variant
availability depends on the selected provider and model.

## Environment

```bash
source agent/scripts/agent-project-env.sh
```

This adds `agent/scripts/bin/` to `PATH` (`agent-gh`, `agent-git`).

Agent jobs may create a repo-local plain Python virtual environment at
`machine/venv/` when packages are needed:

```bash
python3 -m venv machine/venv
source machine/venv/bin/activate
python -m pip install ...
```

Do not use `--system-site-packages`. Keep `machine/venv/` local and uncommitted.
Use the root `requirements.txt` as the centralized dependency spec. Update it
when committed code or knowledge samples require non-standard packages.

## One-command setup

For a new GitHub repo, run this once after creating or confirming
`credentials/github_agent.txt`:

```bash
./agent/setup/setup-once.sh OWNER/REPO
```

This verifies the GitHub repo with agent credentials, configures `origin`,
pushes `main`, creates labels, and registers and starts both the modifying agent
runner and the dedicated read-only inspect runner.

Preview without changing GitHub or git remotes:

```bash
./agent/setup/setup-once.sh OWNER/REPO --dry-run
```

## Self-hosted runner internals

These lower-level scripts remain useful for troubleshooting:

```bash
./agent/setup/setup-github-runner.sh
./agent/setup/setup-github-runner.sh --inspect
./agent/setup/start-github-runner.sh
./agent/setup/start-github-runner.sh --inspect
./agent/setup/status-github-runner.sh
./agent/setup/status-github-runner.sh --inspect
./agent/setup/stop-github-runner.sh
./agent/setup/stop-github-runner.sh --inspect
./agent/setup/clean-runner-workdir.sh   # stop runner first; clears _work/ and _diag/
./agent/setup/clean-runner-workdir.sh --inspect
```

When managing an installed repository from the template checkout, the
installer's `shutdown` and `resume` stages manage both runner profiles in one
command:

```bash
python3 autopilot_repo.py shutdown --local-dir /path/to/repo
python3 autopilot_repo.py resume --local-dir /path/to/repo
```

Runner installs: `machine/runner/github-actions/` and
`machine/runner/github-actions-inspect/` (registration secrets — never commit).

The modifying workflows use the `agent` label. Conversational inspect issues
and `/agent inspect` use `agent-inspect`, allowing one inspection to run at the
same time as a modifying job. A single inspect runner still serializes multiple
simultaneous inspection conversations.

### Job sync and locking

Agent workflows run **in this repo checkout**. Before each job, `agent/scripts/agent-job-wrapper.sh`:

1. Acquires a per-issue lock (`../machine/lock/issue-<N>.lock`) — only same-issue jobs serialize
2. Runs inside the job checkout prepared for the issue branch
3. If busy on the same issue, posts an **Agent-abk is busy** comment on the triggering issue and skips

GitHub Actions also uses coarse per-event concurrency groups so unrelated issues can still run in parallel.

## Orchestration state

Comment dedupe files: `machine/state/` (machine-local, not synced).

Agent run logs: `../machine/runs/issue-<N>/` (local only, not committed to GitHub).
