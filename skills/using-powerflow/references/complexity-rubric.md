# Complexity × Risk Rubric (Small / Big)

Two classifications only. **Small** tasks skip subagent delegation and reviews; **Big** tasks use them. Complexity and risk are assessed as SEPARATE axes — file count alone never decides.

## Axes

### Complexity (how hard is it to build?)

| Signal | Low | High |
|---|---|---|
| Files changed | 1–2 files, one module | 3+ files, new module, or 3+ modules touched |
| New abstraction | No (no new class, interface, or module) | Yes |
| Cross-cutting | Single module | Affects 3+ modules |
| State / schema migration | No | Yes |
| Unknowns | Familiar area, APIs known | Unknown files/APIs, first touch in area |

### Risk (how bad is it if wrong?)

| Signal | Low | High |
|---|---|---|
| Blast radius | Isolated (docs, internal tooling, local UI) | Auth/authz, payments, PII/secrets, data loss, public API/schema contract |
| Reversibility | Trivial revert | Migration, cross-service change, published contract |
| Regression risk | Low — isolated | Medium or high |
| Validation needed | Manual or unit tests only | Integration or e2e tests |

## Decision Matrix

| Complexity | Risk | Classification | Workflow |
|---|---|---|---|
| Low | Low | **Small** | Direct execution, relevant checks |
| High | Low | **Big** | Planning and staged execution |
| Low | High | **Big** | Tightened planning and verification; independent review proportionate to risk (a 1-file auth change still gets a reviewer) |
| High | High | **Big** | Full Powerflow with review and evidence gates |

Uncertain on either axis → **Big** (safer gate).

## Phase Effects

| Phase | Small | Big |
|---|---|---|
| Brainstorming | Direct discovery, scope confirmation with user | Discovery subagent, Checkpoint A (approach selection) |
| Planning | Plan written directly, no reviews | Plan Drafter + Plan Reviewer loop |
| Executing | Direct implementation + one-line scope check | Implementer subagent + Implementation Reviewer |
| Finishing | Tier 1+2 always, Tier 3 on merge result (waivable, recorded) | Full Tier 1→2→3 before merge/PR; waiver only recorded, Tier 1+2 never skipped |

## Mid-Execution Escalation (Small ➔ Big)

If a task was initially classified as **Small**, but during execution:

- Scope expands beyond 2 files, OR
- Unforeseen cross-module dependencies or schema migrations arise, OR
- A new architectural abstraction becomes necessary, OR
- Regression risk proves higher than anticipated, OR
- The change touches auth/payment/migration, blast radius grows, or reversibility drops:

**Trigger Mid-Flight Escalation**:
1. STOP direct execution immediately.
2. Update classification in `<task-dir>/summary.md` to `Big` (with one-line reason, noting which axis changed).
3. Switch to `powerflow-planning` (or Checkpoint A in `powerflow-brainstorming` if the high-level approach must change).
4. Draft a formal plan (`plan-v1.md`) and run the subagent review loop before resuming implementation.

## Scope-Change (Big, after plan lock)

If the locked Scope proves insufficient, do NOT expand silently: write
`<task-dir>/reports/scope-change.md` (Trigger / Evidence `file:line` / Requested change /
AC impact / User decision / Re-review), get recorded user approval, amend `plan-final.md`,
re-run the reviewer (abbreviated). An approved scope-change does NOT reset the 3-round
review cap.

## Override

If the user disagrees with the classification, mark `[OVERRIDE BY USER]` in the brief and use the user's choice.
