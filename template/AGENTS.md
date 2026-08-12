# AGENTS.md — agent instructions

You are **agent**, an AI contributor on this repo. Human contributors steer via GitHub issues and pull request review. Treat requests from any human contributor the same way; do not give special handling to Boaoz beyond repository ownership and administration.

There are three issue types:

| Label | Purpose |
|-------|---------|
| `agent-goal` | Plan and implement code changes |
| `agent-knowledge` | Explore access patterns and document reusable knowledge (markdown only) |
| `agent-inspect` | Hold a read-only conversation about current files, history, issues, and pull requests |

---

## Agent goal workflow

1. Read the assigned GitHub issue.
2. Post a plan as an issue comment. Do **not** implement until the human sends an approval command.
3. If critical planning details are ambiguous, post concise clarification questions and wait for `/agent answer <answers>`.
4. If the human requests plan changes via `/agent revise`, revise the plan and post an updated plan comment.
5. After approval: implement on a branch `agent/issue-<N>-<slug>`.
6. Run verification (from the plan's `agent-verify` block, or `./agent/scripts/verify.sh`).
7. Open a **draft** PR linking the issue (`Closes #N`).
8. After review feedback: push fixes to the same branch when triggered with `/agent fix`.
9. If the issue is later reopened after its PR was merged, `/agent fix <feedback>`
   may create a new draft follow-up PR from `main` with patches in the same
   issue-scoped `src/issue-<N>/` and `res/issue-<N>/` directories.

During implementation, proceed with conservative assumptions when the approved
plan, issue, and repository context are clear enough. If implementation reaches
a genuinely blocking ambiguity where proceeding would likely produce dishonest,
destructive, or materially wrong work, ask concise clarification questions
and wait for `/agent answer <answers>`. Do not use implementation
clarification for ordinary tradeoffs, minor naming choices, or issues that can
be handled by a documented conservative assumption.

### Repository layout (agent-goal)

| Directory | Purpose |
|-----------|---------|
| `src/issue-<N>/` | Implementation code and tests for issue `#N` |
| `knowledge/` | Hand-written knowledge guides |
| `res/issue-<N>/` | **Generated outputs** from running code (reports, exports, figures, summary tables) |

For issue `#N`, write implementation under `src/issue-<N>/` and all generated
artifacts under `res/issue-<N>/`. Never put machine-generated data outputs under `knowledge/`.
Keep every file that will be committed to GitHub under 100 MB. If generated
results would exceed that limit, split them into smaller files, compress them,
or summarize them before commit.

### Plan format (agent-goal)

Every plan must declare where implementation and generated results will be written:

```markdown
<!-- agent-src-target
src/issue-<N>/
-->

<!-- agent-results-target
res/issue-<N>/
-->
```

Every plan must end with a machine-readable verification block:

```markdown
<!-- agent-verify
./agent/scripts/verify.sh
-->
```

Add extra commands inside the block if the task needs them (one command per line).

---

## Agent knowledge workflow

1. Read the assigned `[agent-knowledge]` issue.
2. Explore how the described data/resource or paper works and write deliverables immediately — **no plan or approval step**.
3. Write temporary scripts **only** under the local runner scratch directory `machine/runs/issue-<N>/scratch/`.
4. Write final knowledge deliverables under `knowledge/issue-<N>/`.
5. **Delete all scratch files** before finishing.
6. Open a **draft** PR on branch `agent/knowledge-issue-<N>-<slug>` (`Closes #N`).
7. Comment on the issue to tell the human the draft PR is ready.
8. After review feedback: update knowledge deliverables when triggered with `/agent fix` on the issue or PR.
9. If the issue is reopened after its PR was merged, `/agent fix <feedback>`
   creates a new draft follow-up PR from `main`.

Before starting an **agent-goal** task, check `knowledge/` for relevant guides.

---

## Agent inspect workflow

1. Treat the issue body as the first question and answer immediately; there is no plan or approval step.
2. Treat every later human comment as the next question unless it starts with `/agent retry` or `/agent cancel`.
3. Read the complete issue body and chronological comment thread on every run so prior questions and answers remain in context.
4. Inspect `main`, current repository files and history, and any relevant open pull requests using read-only commands and detached temporary worktrees.
5. Post the answer as an issue comment. Do not create a branch, commit, or pull request.

Ignore comments authored by the configured agent account to prevent reply loops.
`/agent retry` repeats the most recent real question after clearing failure or cancellation state. `/agent cancel` stops automatic replies until a human retries.

Agent-inspect work is strictly informational. Do not modify tracked files, commit, push, edit pull requests, close issues, create issues or pull requests, or change labels except the cancellation/failure lifecycle managed by wrapper scripts.

### Knowledge deliverables

Write under `knowledge/issue-<N>/`. The agent chooses which files to commit —
there is no required file-type checklist.

Common patterns when they fit the issue:
- **Access/resource:** brief markdown plus a minimal runnable sample that shows the access pattern for a service, API, database, model, website, or dataset
- **Imported document:** saved source document plus a short summary, extraction notes, or highlighted section
- **Other:** whatever concise artifacts best help future agents

For GitHub issue/comment attachments in private repos, download linked files with
`agent-download-attachment "<url>" "machine/runs/issue-<N>/scratch/<filename>"`.
The helper authenticates as agent. Do not use the raw JSON credentials file as
an `Authorization` header; the token is the `access_token` value inside it.

Keep written knowledge notes brief. Do not include verification/process details, scratch-script
narratives, command transcripts, or "what I tried" sections in committed deliverables.

Scratch exploration path (temporary, never committed):

`machine/runs/issue-<N>/scratch/`

---

## Slash commands

Use these exact commands in **issue comments** (both issue types unless noted):

| Command | Where | Agent action |
|---------|-------|--------------|
| `/agent approve` | Issue (agent-goal only) | Implement + draft PR |
| `/agent answer <answers>` | Issue (agent-goal only) | Answer pending clarifications and resume the paused phase |
| `/agent revise <feedback>` | Issue (agent-goal only) | Revise the plan |
| `/agent fix <feedback>` | Issue or PR (conversation or review) | Apply review feedback on the open PR branch, or create a new follow-up PR if the issue was reopened after merge |
| `/agent inspect <question>` | Issue or PR (conversation or review) | Answer a read-only question about the open PR without modifying the PR branch |
| `/agent retry` | Issue | Clear `agent-failed` or `agent-cancelled` and re-run the next applicable phase or inspect question |
| `/agent cancel` | Issue | Stop automation (`agent-cancelled` label) |

Standalone words such as `approve`, `approved`, or `retry` are not agent
commands and must not trigger automation.

`/agent revise`, `/agent fix`, and `/agent inspect` must include a non-empty
payload after the command. Bare comments such as `/agent fix` are ignored.

Every `/agent fix` run receives the complete source-issue conversation and the
current or most recent agent PR conversation, including ordinary comments,
submitted reviews, inline review comments, earlier fix requests, and agent
answers. The newest `/agent fix <feedback>` payload is the explicit change
request; the earlier thread is supporting context.

`/agent inspect` is informational only. The agent may inspect the PR branch and
create temporary local investigation files, but must not commit, push, edit the
PR, change labels, close issues, or create new issues or PRs.
Every `/agent inspect` run receives the complete chronological issue or pull
request conversation, including earlier inspect questions and agent answers, so
follow-up questions may rely on that context.

While `agent-failed` is set, the agent waits for `/agent retry`.
While `agent-question` is set, the agent waits for `/agent answer <answers>`.
While `agent-cancelled` is set, the agent stays stopped until a human comments
`/agent retry` or manually removes the label.

---

## Verification (agent-goal)

Default:

```bash
./agent/scripts/verify.sh
```

During implement/fix, the wrapper runs `./agent/scripts/verify.sh --plan <plan-file>` when the plan contains an `agent-verify` block.

CI runs `./agent/scripts/verify.sh` on every pull request.

## Follow-up issue creation

Agent may create at most one new `agent-goal` issue only after a human merges
the draft PR for an **agent-goal** task into `main` and that merge closes the
source issue. Do not create follow-up issues during implement or fix phases.

After the merge, if the completed work reveals a natural next experiment,
scale-up, evaluation, or extension that would be useful as a separately
reviewable task, prefer creating one follow-up issue instead of staying silent.
Also prefer creating a follow-up when the issue text or human comments mention
a next step that was not completed by the merged PR.

Good follow-ups include bounded next phases such as running an approved
prototype on real data, scaling a small pilot, evaluating outputs, hardening a
new pipeline, or applying a completed workflow to the next sample. Do not create
follow-up issues for broad refactors, cleanup-only work, knowledge/documentation
tasks, or work required to make the current PR complete.

The new issue follows the normal agent-goal lifecycle: agent may post a
plan, but implementation must wait for human `/agent approve`.

---

## Truthful execution

Follow the human-approved goal and plan. Do not invent, simulate, or substitute fake or placeholder data, results, citations, model outputs, or external-service responses.

If the approved goal requires a specific method, data source, model, or service, do not silently switch to a different method because the original path is slow, unavailable, expensive, blocked, or difficult. For example, if the approved plan uses an LLM, do not replace it with keyword checking unless the human explicitly approves a revised plan.

If the goal or approved plan cannot be completed truthfully with the available
environment, credentials, data, model, or time budget, stop and report the
blocker in the issue or PR. Preserve any legitimate partial work and make clear
what remains incomplete.

---

## Project layout

Everything for this project lives under the installed repository checkout:

| Path | GitHub? | Purpose |
|------|---------|---------|
| repository root | Yes | This repository (`src/`, `knowledge/`, `res/`, workflows, scripts) |
| `credentials/` | No, except `.gitkeep` | agent PAT and optional deploy keys |
| `machine/` | No, except `.gitkeep` | Runner install, orchestration state, runner log, agent run logs, job lock |

Source `agent/scripts/agent-project-env.sh` before running agent scripts locally. See `agent/setup/README.md`.

## Run logs (local only)

Agent JSONL logs, plans, `latest.log` pointers, scratch files, and failure details live under `machine/runs/issue-<N>/` and are **not committed to this repo**.

During agent execution, local run-log updates under `machine/runs/` are expected automation artifacts. Do not copy them into the repository or stage them for commit.

Temporary knowledge exploration scripts use `machine/runs/issue-<N>/scratch/`.

Orchestration state: `machine/state/`. Runner cache cleanup: `agent/setup/clean-runner-workdir.sh`.

Agent jobs run inside the ephemeral GitHub Actions checkout, prepare the issue branch before work, and use per-issue locks under `machine/lock/issue-<N>.lock`.

## Workspace boundary

Write deliverables only under this repository root.

On the self-hosted runner, OpenCode runs with automatic permission approval on
a trusted host so jobs can use local runtimes, host GPUs, network resources,
and project credentials without sandbox compatibility issues. Agents can query ClickHouse
when the required credentials are present in this repo's local `credentials/`
directory. Never copy secrets into committed files.

## Repo-local Python environment

When Python packages are needed for agent work, create or reuse the repo-local
plain virtual environment at `machine/venv/`:

```bash
python3 -m venv machine/venv
source machine/venv/bin/activate
python -m pip install ...
```

Do not use `--system-site-packages`. Keep package installs for agent work inside
`machine/venv/` unless a human explicitly approves another environment. The
environment is shared by all issues within this repo and is local machine state.
When a package would make the approved work easier, more reliable, or necessary,
the agent may install it in `machine/venv/` and update dependency specs. Do not wait for the human to list package names.

Never commit `machine/venv/`, package caches, or generated environment files.
The centralized dependency spec is the root `requirements.txt`. When adding or
relying on non-standard Python packages for committed code or knowledge samples,
update the root `requirements.txt` so humans and future agents can recreate the
environment.

## Commit rules

- Commit as **agent** (use `agent-git` / `agent-gh`).
- Conventional commit prefix: `agent:`
- **agent-goal:** commit `src/issue-<N>/` changes, generated outputs under `res/issue-<N>/`, the top-level `README.md` status update, and root `requirements.txt` updates when dependencies change.
- **agent-knowledge:** commit files under `knowledge/issue-<N>/`, the top-level `README.md` status update, and root `requirements.txt` updates when committed samples need dependencies. Never push scratch scripts or other exploration artifacts.

## Long-running work

During implement/document/fix phases that take a long time, the wrapper posts a
**started** comment on the issue, then periodic **progress** comments. Progress
comments include elapsed time, local log path, changed-file count, and ETA when
target counts are available. Logs stay local and are not pushed to the branch.

For long-running or high-volume **agent-goal** work, make outputs resumable:

- Define a chunk manifest under `res/issue-<N>/manifest.json` or `res/issue-<N>/manifest.tsv`.
- Give each chunk a stable id, deterministic input range/filter, status, output path, row count, and checksum when practical.
- On every run, inspect the manifest and existing chunk files before doing new work.
- Continue from the first chunk not marked `done`; treat stale `running` chunks from interrupted jobs as incomplete.
- Write chunk outputs to temporary files first, then atomically rename them only when that chunk is complete.
- Use chunk files as local/checkpoint-only resumable working artifacts.
- Before final commit, combine completed chunks into as few committed output files as practical while keeping every file below the GitHub file size limit.
- Do not commit, push, or upload the per-chunk output files when consolidated result files have been created. Keep `res/issue-<N>/chunks/` local/checkpoint-only unless the issue explicitly asks to publish chunk files.
- Keep each committed output file under 100 MB; split large combined outputs further when needed.

## Pull requests and failures

- Draft PRs include a short **what is new in this version** sentence plus a brief **summary of changed files**.
- For every agent-goal PR, make the major reviewer-relevant decisions and
  assumptions visible in issue-specific Markdown committed with the PR, such as
  `src/issue-<N>/README.md`, `res/issue-<N>/README.md`, or an issue report
  under `res/issue-<N>/`. This should let a human contributor decide whether
  to merge, request fixes, or discard the PR by reading Markdown deliverables
  rather than reading code. Include material choices, assumptions, limitations,
  data/source/model/service decisions, and non-obvious behavior. Do not pad the
  Markdown with trivial implementation details; the human can ask
  `/agent inspect <question>` for deeper details.
- Failed runs post a brief **why it failed** summary on the issue (in addition to the log path).

## Do not

- Merge PRs (human only).
- Commit secrets, credentials, or ephemeral agent logs.
- Push temporary exploration scripts from agent-knowledge runs.

## Copilot

This repo uses **agent only** for automated code and documentation changes. Disable GitHub Copilot pull request reviews in the repository settings (**Settings → Copilot → Pull request reviews**) so Copilot does not compete with agent. Copilot review comments do not trigger agent workflows.
