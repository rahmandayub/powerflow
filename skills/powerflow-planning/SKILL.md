---
name: powerflow-planning
description: Load when a Context Brief or Diagnosis Report exists. Writes the implementation plan directly for Small tasks, or drafts and reviews it via subagents for Big tasks, ending with an approved plan-final.md.
---

# Phase 2: Powerflow Planning

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (exit 2/3 → ask the user).
- Read `<task-dir>/summary.md` first if it exists, then the Context Brief at `<task-dir>/context/brief.md`.
- Bug fix routed from debugging: if no brief exists, read the most recent Diagnosis Report from `<task-dir>/executions/diagnostics/` instead and treat it as the context document.
- Announce: `"I'm using the powerflow-planning skill to draft the implementation plan."`

## 1. Small Tasks — Write Directly

Write `<task-dir>/plans/plan-final.md` yourself with the Implementation Contract (below) and a step list. No reviews. Update `summary.md` and proceed to [powerflow-executing](../powerflow-executing/SKILL.md).

## 2. Big Tasks — Draft Plan v1 (Delegated)

Spawn a subagent using the **Plan Drafter** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). Verify `<task-dir>/plans/plan-v1.md` exists on disk, then read it.

### Implementation Contract (in every plan)

- **Scope**: exact files to modify
- **Must Not Change**: off-limits files/behaviors
- **Acceptance Criteria**: testable pass/fail list
- **Out of Scope**: explicit exclusions

### Plan Structure (Big)

- The contract above
- Assumptions section (each with a way to verify it)
- Steps: task ID (TASK-001…), description, evidence link (`file:line`), the verification method (failing test for logic/code, or explicit verification command/schema check/lint for config/UI/scripts), the minimal implementation, the verification command, the atomic commit message

## 3. Checkpoint B (Big)

Present the plan's scope, files to modify, out-of-scope files, and acceptance criteria. Ask the user to confirm or adjust. If the user changes the approach: return to [powerflow-brainstorming](../powerflow-brainstorming/SKILL.md) to re-run Checkpoint A. If the approach changes a second time, ask the user what they actually want instead of re-drafting again.

## 4. Plan Review Loop (Big)

Spawn a subagent using the **Plan Reviewer** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). It writes `<task-dir>/reviews/plan-review.md`.

- **APPROVED** → proceed to Final Plan Lock.
- **REVISE AND RESUBMIT** → revise the plan (v2, v3…), re-run the Plan Reviewer.
- **BLOCKED** → revise and re-run.
- **Escalation**: if the second review round returns with the same blockers, OR if 3 review rounds (v3) are reached without approval → STOP and ask the user, writing the request to `<task-dir>/reports/blocker.md` (template below).

## 5. Final Plan Lock

1. Write `<task-dir>/plans/plan-final.md` with the `APPROVED` verdict and the full contract + steps.
2. Update `summary.md`: phase done, output path, next phase (Executing).
3. Transition to [powerflow-executing](../powerflow-executing/SKILL.md).

## Blocker Report Template (`<task-dir>/reports/blocker.md`)

```markdown
# Blocker: <one-line problem>
## Decision needed: <yes/no or selection>
## Context: <why we stopped>
## Options:
(a) ...
(b) ...
## Resume point: <file + step>
```
