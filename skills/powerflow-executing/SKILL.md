---
name: powerflow-executing
description: Load when an approved plan exists. Implements Small tasks directly in the orchestrator, or delegates Big tasks to an Implementer subagent with TDD steps, then runs the implementation review and verification.
---

# Phase 3: Powerflow Executing

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (add `--no-gitignore` to skip `.gitignore` mutation; exit 2/3 → ask the user). Announce explicitly if `.gitignore` was created or modified.
- Read `<task-dir>/summary.md` first if it exists, then the approved Final Plan at `<task-dir>/plans/plan-final.md`.
- Extract the **Implementation Contract** — it is the highest authority; do not violate it.
- Announce: `"I'm using the powerflow-executing skill to implement the approved plan."`

## 1. Branch Isolation

1. Run with porcelain output to capture the Git State:
   `bash <skills-root>/powerflow-executing/scripts/isolate-branch.sh --task-slug <task-slug> [--base-branch <integration-target>] --porcelain`
   - `--base-branch` names the INTEGRATION target (the branch work merges back
     into, e.g. `main`) and may differ from the current branch. Omit it to
     resolve from the current branch's upstream, else the repo default
     (`origin/HEAD`, `main`, `master`); if none resolves, the script fails and
     you must pass it explicitly.
   - Exit 0 → proceed.
   - Exit 1 → error: report it and stop.
   - Exit 2 → detached HEAD: warn the user and use the detached-HEAD finishing menu; do not create a branch.
   - Exit 4 → dirty tree: STOP, ask the user to commit/stash or re-run with `--allow-dirty`.
2. Write all five Git State fields to `summary.md` from the `--porcelain` output
   (`BASE_BRANCH` → Base branch = short integration name, `BASE_REF` → Base ref =
   exact ref, `BASE_SHA` → Base SHA = merge-base of ref and HEAD at isolate time,
   `TASK_BRANCH` → Task branch, plus `Isolation: <ACTION> — <date>`). The branch the session started on is NOT
   necessarily the base — record them as separate fields; Finishing needs the base.
   - `ACTION=created`: fresh `powerflow/<slug>` branch; Base SHA equals HEAD at
     isolate time.
   - `ACTION=reused`: continuing directly on an existing branch (e.g. a feature
     branch with its own upstream). The existing branch is the TASK branch; the
     Base branch stays the integration target and Base SHA is the fork point.
     A branch tracking `origin/itself` is never taken as the integration target
     (falls back to repo default); a resolved base equal to the current branch
     is an error — pass the real merge target explicitly.

## 2. Implement

- **Small**: implement directly. Write tests for non-trivial logic (or run concrete verification commands for non-testable code/config/scripts), verify, and commit.
  - **Mid-Flight Escalation**: if during execution the scope unexpectedly expands (>2 files, new abstractions, schema migrations, cross-cutting dependencies) or risk rises (auth/payment/migration touched, blast radius grows, reversibility drops, regression risk revised up), STOP direct editing immediately, update classification to `Big` in `summary.md` (noting which axis changed — `validate-transition.sh` reads this line as the current classification), and transition to [powerflow-planning](../powerflow-planning/SKILL.md).
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

- **Big**: append a short verification section to `<task-dir>/executions/verification-ledger.md`: files modified, tests run and results, acceptance criteria pass/fail with evidence, review verdicts. Record the tested commit as `Tested SHA: <git rev-parse HEAD>` (the validator compares it to HEAD).
- **Small**: write the scope-check result to `<task-dir>/scope-check.txt`: one line per `AC-00X` with `PASS|FAIL` plus evidence (`file:line` or `log:timestamp`), e.g. `AC-001 PASS src/foo.ts:42`. The validator reads this file for Small tasks (no ledger, no review file by design).
- Update `summary.md`: phase done, output paths, next phase (Finishing).
- Show the final diff (e.g. `git diff` against the base branch, or `git log --oneline` of the commits) and announce: `"Implementation complete and verified."`

## Non-Negotiable Behaviors

- **Scope lock with recorded expansion only**: never edit, create, or delete a file
  outside the contract's Scope. If the scope proves insufficient: STOP, append a
  new `## Request SC-00X` block to `<task-dir>/reports/scope-change.md` (Trigger /
  Evidence `file:line` / Requested change / AC impact / User decision / Re-review —
  format in [powerflow-planning](../powerflow-planning/SKILL.md)), get the user's
  recorded approval, amend `plan-final.md` (date + request ID + added paths + reason),
  and re-run the appropriate reviewer before resuming. Never expand scope silently.
  An approved scope-change does NOT reset the 3-round review cap.
  Effective scope is cumulative: `validate-transition.sh` accepts out-of-scope
  diffs covered by ANY completed request (approved + amended + re-reviewed
  ACCEPTED); a newer request never revokes earlier completed paths. The latest
  request must still be complete (or rejected) before transitioning.
- **Verification cycle per step**: failing test (or concrete command check for non-testable tasks) → minimal implementation → verification passes → atomic commit with the task ID. Never group steps into one commit.
- **Never self-approve** (Big): implementation and coverage checks are delegated to an independent subagent.
- **Failure stops the pipeline**: stop and report; never silently patch or skip a failure.
