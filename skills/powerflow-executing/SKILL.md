---
name: powerflow-executing
description: Load when an approved plan exists. Implements Small tasks directly in the orchestrator, or delegates Big tasks to an Implementer subagent with TDD steps, then runs the implementation review and verification.
---

# Phase 3: Powerflow Executing

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (exit 2/3 → ask the user).
- Read `<task-dir>/summary.md` first if it exists, then the approved Final Plan at `<task-dir>/plans/plan-final.md`.
- Extract the **Implementation Contract** — it is the highest authority; do not violate it.
- Announce: `"I'm using the powerflow-executing skill to implement the approved plan."`

## 1. Branch Isolation

1. Record the current branch in `summary.md` (the finishing phase needs it).
2. Run: `bash <skills-root>/powerflow-executing/scripts/isolate-branch.sh --task-slug <task-slug>`
   - Exit 0 → proceed.
   - Exit 1 → error: report it and stop.
   - Exit 2 → detached HEAD: warn the user before continuing.
3. Record the resulting branch in `summary.md` (`powerflow/<slug>` or the existing branch).

## 2. Implement

- **Small**: implement directly. Write tests for non-trivial logic (or run concrete verification commands for non-testable code/config/scripts), verify, and commit.
  - **Mid-Flight Escalation**: if during execution the scope unexpectedly expands (>2 files, new abstractions, schema migrations, cross-cutting dependencies), STOP direct editing immediately, update classification to `Big` in `summary.md`, and transition to [powerflow-planning](../powerflow-planning/SKILL.md).
  - After the last edit, run the **one-line scope check**: list the files changed and confirm each is in the contract's Scope. No subagent reviews.
- **Big**: spawn a subagent using the **Implementer** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). It executes steps task-by-task (failing test / concrete verification step → minimal implementation → test passes → atomic commit `TASK-XXX: ...`), appends to `<task-dir>/executions/execution-log.md`, and stops on failure.

## 3. Failures (Big)

If a step fails: load [powerflow-debugging](../powerflow-debugging/SKILL.md) to diagnose, then re-spawn the Implementer with the Diagnosis Report path and instructions to fix only the failed step. If the implementer escalates, present the Blocker Report to the user.

## 4. Implementation Review (Big)

Spawn a subagent using the **Implementation Reviewer** prompt. It writes `<task-dir>/reviews/implementation-review.md`, checking conformance, scope leaks, and that every acceptance criterion has a passing test (coverage is part of this review).

- **ACCEPTED** → proceed to Verification.
- **SEND BACK** → spawn the Implementer to fix the listed defects (commit prefixed `FIX: ...`), then re-run this review.
- **ESCALATE** (e.g. scope damage) → STOP and ask the user immediately with `reports/blocker.md`.
- **Review Cap**: if two consecutive reviews return the same blockers OR 3 review rounds are reached without `ACCEPTED` → STOP and ask the user.

## 5. Verification

- **Big**: append a short verification section to `<task-dir>/executions/verification-ledger.md`: files modified, tests run and results, acceptance criteria pass/fail with evidence, review verdicts.
- **Small**: no ledger needed — the scope check result is enough.
- Update `summary.md`: phase done, output paths, next phase (Finishing).
- Show the final diff (e.g. `git diff` against the base branch, or `git log --oneline` of the commits) and announce: `"Implementation complete and verified."`

## Non-Negotiable Behaviors

- **Scope lock is absolute**: never edit, create, or delete a file outside the contract's Scope. Expanding scope requires the user's OK.
- **Verification cycle per step**: failing test (or concrete command check for non-testable tasks) → minimal implementation → verification passes → atomic commit with the task ID. Never group steps into one commit.
- **Never self-approve** (Big): implementation and coverage checks are delegated to an independent subagent.
- **Failure stops the pipeline**: stop and report; never silently patch or skip a failure.
