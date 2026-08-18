# Complexity Rubric (Small / Big)

Two classifications only. **Small** tasks skip subagent delegation and reviews; **Big** tasks use them. If any criterion says Big, or you are uncertain, classify Big.

## Classification Matrix

| Criterion | Small | Big |
|---|---|---|
| Files changed | 1–2 files | 3+ files, or a new module |
| New abstraction | No (no new class, interface, or module) | Yes |
| Cross-cutting | Single module | Affects 3+ modules |
| State / schema migration | No | Yes |
| Risk of regression | Low — isolated | Medium or high |
| Validation needed | Manual or unit tests only | Integration or e2e tests |

## Decision Flow

1. ALL criteria in the Small column → **Small**.
2. ANY criterion in the Big column → **Big**.
3. Uncertain (criteria split across columns, or files not yet inspected that could change it) → **Big** (safer gate).

## Phase Effects

| Phase | Small | Big |
|---|---|---|
| Brainstorming | Direct discovery, scope confirmation with user | Discovery subagent, Checkpoint A (approach selection) |
| Planning | Plan written directly, no reviews | Plan Drafter + Plan Reviewer loop |
| Executing | Direct implementation + one-line scope check | Implementer subagent + Implementation Reviewer |
| Finishing | Same as Big | Same as Small |

## Mid-Execution Escalation (Small ➔ Big)

If a task was initially classified as **Small**, but during execution:
- Scope expands beyond 2 files,
- Unforeseen cross-module dependencies or schema migrations arise,
- A new architectural abstraction becomes necessary, or
- Regression risk proves higher than anticipated:

**Trigger Mid-Flight Escalation**:
1. STOP direct execution immediately.
2. Update classification in `<task-dir>/summary.md` to `Big` (with one-line reason).
3. Switch to `powerflow-planning` (or Checkpoint A in `powerflow-brainstorming` if the high-level approach must change).
4. Draft a formal plan (`plan-v1.md`) and run the subagent review loop before resuming implementation.

## Override

If the user disagrees with the classification, mark `[OVERRIDE BY USER]` in the brief and use the user's choice.
