# Project Status

This repository uses `agent` to help maintain research code, generated
outputs, and reusable project notes. The agent works through GitHub issues and
pull requests, so human contributors can review what it plans to do before its
changes are merged.

## Current State

- No agent tasks have been completed yet.
- This README should be updated after each completed agent task so it reflects
  the current state of the repository.

## Repository Layout

- `src/issue-<N>/` contains source code written for GitHub issue `<N>`.
- `res/issue-<N>/` contains outputs generated for GitHub issue `<N>`.
- `knowledge/issue-<N>/` contains reusable notes, guides, or documentation
  created for GitHub issue `<N>`.
- `credentials/` stores local credentials and is not uploaded to the GitHub
  repo.
- `machine/` stores local agent run state and is not uploaded to the GitHub
  repo.

## Working With agent

Use GitHub issues to ask the agent to do work. An `agent-goal` issue is for
creating or changing code and outputs. An `agent-knowledge` issue is for
creating reusable documentation. An `agent-inspect` issue is a read-only
conversation about current files, history, issues, or pull requests.

For `agent-goal` issues, the agent first posts a plan. A human contributor
should review that plan before allowing implementation. The agent then works in
an issue-specific folder, opens a pull request, and waits for review.

Common issue comments:

- `/agent approve` lets the agent implement an approved `agent-goal` plan.
- `/agent revise <feedback>` asks the agent to revise a plan.
- `/agent answer <answers>` answers pending clarification questions from the agent.
- `/agent fix <feedback>` asks the agent to update an open pull request, or to
  create a follow-up PR when the source issue was reopened after merge. The
  agent receives the complete source-issue and PR discussion, including reviews
  and inline comments, while treating the newest fix payload as the requested
  change.
- `/agent inspect <question>` asks the agent to answer a read-only question
  about an open pull request without changing that pull request. Later inspect
  questions receive the complete issue or PR conversation, including earlier
  inspect questions and answers.
- `/agent retry` restarts a failed or cancelled agent task from the next
  applicable step.
- `/agent cancel` stops automation for that issue.

Plain words such as `approve` or `retry` are not agent commands. Use the
`/agent ...` form so the request is explicit.

Within an `agent-inspect` issue, the issue body is the first question and every
later human comment is automatically treated as another question. The agent
receives the complete conversation each time. Only `/agent retry` and
`/agent cancel` are treated as control commands instead of questions.

`/agent revise`, `/agent fix`, and `/agent inspect` require feedback or a
question after the command.

## What To Expect

The agent should follow the issue goal and the approved plan. If it cannot
complete the task truthfully, it should say so instead of inventing data or
switching to a different approach without human approval.

Large jobs may be split into resumable chunks while the work is in progress,
but pull requests should contain the final combined outputs rather than many
temporary chunk files.
