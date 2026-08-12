# autopilot repo template

This private GitHub repository (`Boaoz/autopilot_repo_template`) is a reusable
installer for the `agent` GitHub issue workflow. Clone it wherever you want to
prepare a target repository for background agent work.

The installer and this README live at the repository root; the files that are
copied into target repositories live under `template/`.

## What is included

- Lifecycle CLI: `autopilot_repo.py`
- Installer documentation: `README.md`
- Host command dependencies: root `requirements.txt`
- Copyable payload under `template/`
- Agent framework internals grouped under `template/agent/`, including
  orchestration scripts, setup scripts, tests, and command wrappers
- GitHub workflows under `template/.github/`
- Empty payload scaffold directories: `src/`, `res/`, `knowledge/`, `credentials/`,
  and `machine/`

## What is excluded

- `src/issue-*`
- `res/issue-*`
- `knowledge/issue-*`
- `machine/` logs, locks, runs, state, and runner installs
- Real credential files

## Fresh-system prerequisites

Install the commands in root `requirements.txt`: `git`, `gh`, `bash`, `python3`,
`curl`, `screen`, and `opencode`. This host dependency list is not copied; the
separate `template/requirements.txt` becomes each target repository's Python
requirements.

Before `make-live`, fill the copied `credentials/github_agent.txt` with a
matching GitHub username and access token. The credential file remains ignored.

## Install into a repo

Clone this template repository first:

```bash
git clone https://github.com/Boaoz/autopilot_repo_template.git
cd autopilot_repo_template
```

First create the GitHub repository manually under a GitHub organization, not a
personal account. The organization must have the configured agent account as a
member, and that account must have **Admin** access to the specific repository
before the installer runs.

This matters because normal write/push permission is enough for commits and
pull requests, but it is not enough to register the self-hosted GitHub Actions
runner. Without repo Admin access, the workflow files can be pushed but the
agent will not become live.

Then copy the relevant template files into the checkout:

```bash
python3 autopilot_repo.py prepare \
  --repo-url https://github.com/OWNER/REPO.git \
  --local-dir /path/to/local/checkout
```

The default is `openai/gpt-5.6-sol` with the `medium` OpenCode variant. Override
either setting during `prepare` or a one-command install:

```bash
python3 autopilot_repo.py prepare \
  --repo-url https://github.com/OWNER/REPO.git \
  --local-dir /path/to/local/checkout \
  --model openai/gpt-5.6-luna \
  --reasoning high
```

Use the exact OpenCode provider/model ID, such as `openai/gpt-5.6-sol`,
`openai/gpt-5.6-luna`, or `xai/grok-4.5`. Variants are `low`, `medium`, `high`,
`xhigh`, `max`, and `ultra`; availability varies by model. Both selections are
saved in `agent/opencode-profile.json` and preserved by `make-live`.

After filling `/path/to/local/checkout/credentials/github_agent.txt`, make
the workflow live:

```bash
python3 autopilot_repo.py make-live \
  --repo-url https://github.com/OWNER/REPO.git \
  --local-dir /path/to/local/checkout
```

The live step accepts the invitation as the configured agent account when one
is pending, commits and pushes with those credentials, creates labels, and
registers and starts separate modifying and read-only inspect runners.

For a one-command install when the target credential file is already filled,
use the default `install` stage.

Preview the complete install sequence without cloning, copying template files,
changing git state, calling GitHub, or starting runners:

```bash
python3 autopilot_repo.py install \
  --repo-url OWNER/REPO \
  --local-dir /path/to/local/checkout \
  --dry-run
```

## Shut down local agent runners

Gracefully stop active agent processes and close both repository-specific
runner screen sessions:

```bash
python3 autopilot_repo.py shutdown \
  --local-dir /path/to/local/checkout
```

`shutdown` does not require `--repo-url` or GitHub credentials. It sends an
interrupt to the modifying and inspect runners, waits up to 15 seconds for each
screen to exit, and closes any matching screen that remains. It does not remove
runner installations, machine state, branches, or credentials. Running it when
the runners are already stopped is safe.

Resume both existing runner processes without repeating installation or runner
registration:

```bash
python3 autopilot_repo.py resume \
  --local-dir /path/to/local/checkout
```

`resume` derives `OWNER/REPO` from the checkout's `origin`, starts the modifying
and inspect runner screens, and leaves already-running screens alone. It does
not commit, push, create labels, or re-register runners. Interrupted issues keep
their local state and checkpoints; use `/agent retry` when the issue remains in
a failed or cancelled state.
