---
name: powerflow-planning
description: Load when a Context Brief or Diagnosis Report exists. Writes the implementation plan directly for Small tasks, or drafts and reviews it via subagents for Big tasks, ending with an approved plan-final.md.
---

# Phase 2: Powerflow Planning

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (add `--no-gitignore` to skip `.gitignore` mutation; exit 2/3 → ask the user). Announce explicitly if `.gitignore` was created or modified.
- Read `<task-dir>/summary.md` first if it exists, then the Context Brief at `<task-dir>/context/brief.md`.
- Bug fix routed from debugging: if no brief exists, read the most recent Diagnosis Report from `<task-dir>/executions/diagnostics/` instead and treat it as the context document.
- Announce: `"I'm using the powerflow-planning skill to draft the implementation plan."`

## 1. Small Tasks — Write Directly

Write `<task-dir>/plans/plan-final.md` yourself with the Implementation Contract (below) and a step list. No reviews. Update `summary.md` and proceed to [powerflow-executing](../powerflow-executing/SKILL.md).

## 2. Big Tasks — Draft Plan v1 (Delegated)

Spawn a subagent using the **Plan Drafter** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). Verify `<task-dir>/plans/plan-v1.md` exists on disk, then read it.

### Implementation Contract (in every plan)

Machine-parseable shape (required by `validate-transition.sh`):

- **Scope**: one repo-relative path per bullet (e.g. `- src/foo.ts`)
- **Must Not Change**: off-limits files/behaviors
- **Acceptance Criteria**: labeled sequentially `AC-001: <testable statement>`, `AC-002: ...`
- **Out of Scope**: explicit exclusions

### Plan Structure (Big)

- The contract above
- Assumptions section (each with a way to verify it)
- Steps: task ID (TASK-001…), description, evidence link (`file:line`), the verification method (failing test for logic/code, or explicit verification command/schema check/lint for config/UI/scripts), which `AC-00X` it covers, the minimal implementation, the verification command, the atomic commit message

## 3. Checkpoint B (Big)

Present the plan's scope, files to modify, out-of-scope files, and acceptance criteria. Ask the user to confirm or adjust. If the user changes the approach: return to [powerflow-brainstorming](../powerflow-brainstorming/SKILL.md) to re-run Checkpoint A. If the approach changes a second time, ask the user what they actually want instead of re-drafting again.

## 4. Plan Review Loop (Big)

Spawn a subagent using the **Plan Reviewer** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). It writes `<task-dir>/reviews/plan-review.md`. The reviewer uses bounded grounding (verify only paths/APIs explicitly named in the plan, max ~5 targeted reads, no broad exploration); v2+ rounds review only the diff plus unresolved findings.

- **APPROVED** → proceed to Final Plan Lock.
- **REVISE AND RESUBMIT** → revise the plan (v2, v3…), re-run the Plan Reviewer.
- **BLOCKED** → revise and re-run.
- **Escalation**: if the second review round returns with the same blockers, OR if 3 review rounds (v3) are reached without approval → STOP and ask the user, writing the request to `<task-dir>/reports/blocker.md` (template below).

## 5. Final Plan Lock

1. Write `<task-dir>/plans/plan-final.md` with the `APPROVED` verdict and the full contract + steps.
2. Update `summary.md`: phase done, output path, next phase (Executing).
3. Run the transition gate:
   `bash <skills-root>/using-powerflow/scripts/validate-transition.sh --task-dir <task-dir> --from planning --to executing`
   On FAIL: do not transition — fix the plan/review/scope-change first.
4. Transition to [powerflow-executing](../powerflow-executing/SKILL.md).

## Scope Changes After Lock

If executing discovers the Scope is insufficient: STOP, append a new request block to
`<task-dir>/reports/scope-change.md` (one block per request, newest last), get
the user's recorded approval, append an Amendment log to `plan-final.md` naming
the request ID (date + ID + added paths + reason), and re-run the Plan Reviewer
(abbreviated: review only the scope-change request plus affected steps, same bounded grounding rule) before resuming. An approved scope-change does NOT reset the
3-round review cap. Never expand silently. Effective scope is CUMULATIVE: every
completed request (approved + amended + re-reviewed ACCEPTED) contributes its
amended paths to the allowed diff — a newer request never revokes paths
completed by an older one. The LATEST request must still be complete (or
rejected) before any transition; a pending/incomplete latest request blocks,
but the earlier paths stay covered.

Request block format (IDs sequential: SC-001, SC-002, …):

```markdown
## Request SC-001 — 2026-01-01
Trigger: <why the scope is insufficient>
Evidence: <file:line showing the need>
Requested change:
+ <added path>
- <removed path, if any>
AC impact: <which AC-00X affected, or none>
User decision: pending|approved YYYY-MM-DD <verbatim>|rejected
Re-review: <review file> <ACCEPTED|SEND BACK>
```

Amendment format: one `## Amendment — <date> (<ID>)` section per request, naming
the ID and EVERY added path (the validator only covers amended paths — an
amendment naming the ID but omitting a path leaves that path out of scope).
Only the latest `Re-review:` line in the block counts. Example:

```markdown
## Amendment — 2026-01-01 (SC-001)
Added src/extra.py (reason: needed helper, scope-change SC-001).
```

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
