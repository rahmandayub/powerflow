---
name: using-powerflow
description: Entry router for the Powerflow skill suite. Establishes the phase workflow (Brainstorming→Planning→Executing→Finishing), the Small/Big classification that controls delegation and reviews, the evidence rule, and the task directory protocol. Load this skill first in any session.
---

# Powerflow Entry Protocol

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/` in the project root (e.g. `.powerflow/2026-07-05-auth-bug`).
- If `<task-dir>/summary.md` exists, read it FIRST. It records the current phase, outputs so far, and user decisions — it is the only state the suite keeps.
- Announce: `"Using powerflow to <purpose>."`

## Skill Directory Layout

Skills are installed as siblings under a common skills root:

```
skills/
├── using-powerflow/
│   ├── SKILL.md
│   └── references/
│       ├── complexity-rubric.md     # Small/Big classification
│       ├── global-epistemology.md   # FACT / ASSUMPTION evidence rule
│       ├── platform-tools.md        # abstract → concrete tool mapping
│       └── subagent-prompts.md      # all subagent prompts, inline
├── powerflow-brainstorming/   # SKILL.md + scripts/init-task-dir.sh
├── powerflow-planning/        # SKILL.md only
├── powerflow-debugging/       # SKILL.md only
├── powerflow-executing/       # SKILL.md + scripts/isolate-branch.sh
└── powerflow-finishing/       # SKILL.md + scripts/squash-branch.sh
```

Cross-skill paths (e.g. `using-powerflow/references/complexity-rubric.md`) resolve relative to the skills root.

---

## Core Rules

1. **Route by request type**:
   - Bug fix, failing test, or crash → load `powerflow-debugging` first.
   - Feature, refactor, or greenfield → load `powerflow-brainstorming` first.
   - Announce the skill before following it.

2. **Classify every task Small or Big** with [complexity-rubric.md](references/complexity-rubric.md). The classification decides delegation and reviews.

3. **Delegation rule**:
   - **Big tasks**: delegate codebase discovery, plan drafting, implementation, and reviews to subagents (registry below). The orchestrator handles only decisions, user communication, reading `<task-dir>` files, and git operations. Low-complexity/High-risk tasks (e.g. a 1-file auth change) still get tightened planning and independent review proportionate to risk.
   - **Small tasks**: the orchestrator may search, read, edit, and test directly. No subagent reviews. After implementation, run the one-line scope check: list the files changed and confirm every one is in the plan's scope.
   - **Mid-Flight Escalation**: if a Small task expands in scope (>2 files, schema changes, new modules) or rises in risk (auth/payment/migration touched, blast radius grows) during execution, immediately stop, reclassify as Big in `summary.md`, and transition to Planning.

4. **Evidence rule**: two labels only — `FACT` (with `file:line`) and `ASSUMPTION` (always marked). Every claim in `brief.md` carries one label; bare claims are rewritten. Full rule: [global-epistemology.md](references/global-epistemology.md).

5. **Task directory lifecycle**:
   - Create it with `powerflow-brainstorming/scripts/init-task-dir.sh`. Exit 2 (exists with content) or 3 (orphan): ask the user — resume, reuse, or new slug. Never overwrite an existing task dir.
   - `summary.md` is the state. If it exists, resume from the phase it records — do not reinitialize. There is no `state.json`.

6. **Escalation**: if any review round fails twice in a row with the same blockers OR reaches 3 review rounds without approval, STOP and ask the user, writing the request to `<task-dir>/reports/blocker.md` (template in `powerflow-planning/SKILL.md`).

7. **Platform mapping**: skill text uses abstract operations ("spawn a subagent"). Map to concrete tools via [platform-tools.md](references/platform-tools.md).

---

## Phase Gating

```
Bug fix → Debugging → Diagnosis Report
Feature → Brainstorming → Context Brief
                  ↓
            Planning → plan-final.md
                  ↓
            Executing → verified implementation
                  ↓
            Finishing → merged / kept / discarded
```

| Phase | Skill | Input | Output | Gate |
|---|---|---|---|---|
| 1a Bug fix | powerflow-debugging | failure report | `<task-dir>/executions/diagnostics/<step>.md` | root cause identified |
| 1b Feature | powerflow-brainstorming | user request | `<task-dir>/context/brief.md` | user confirmed scope (Small) or approach (Big) |
| 2 Plan | powerflow-planning | brief or diagnosis | `<task-dir>/plans/plan-final.md` | approved (Big) or written directly (Small) |
| 3 Execute | powerflow-executing | plan-final | verified changes | review ACCEPTED (Big) or scope check ok (Small) |
| 4 Finish | powerflow-finishing | verified work | merged / kept / discarded | user choice executed |

---

## summary.md Protocol

`summary.md` is the suite's only state. It is written at the end of each phase and read first at the start of every phase.

```markdown
# Powerflow Summary — <task-slug>

## Phase: <Brainstorming|Planning|Executing|Debugging|Finishing> — <date>
Done: <one-line result>
Output: <paths>
User decisions: <verbatim, with date — e.g. "2026-07-05: chose approach B (reason: X)">
Next: <next phase>

## Git State (mandatory from Executing onward)
- Base branch: <short name, e.g. main>
- Base ref: <exact ref from isolate time, e.g. main or upstream/main>
- Base SHA: <merge-base of Base ref and HEAD at isolation>
- Task branch: <powerflow/<slug> or existing branch>
- Isolation: created|reused|detached — <YYYY-MM-DD>
```

- Record user decisions verbatim with the date. Settled decisions are not reopened.
- If a decision later changes, append a new line; never edit the old one.
- Git State rule: the branch the session started on is NOT necessarily the base.
  Base is the isolation source recorded by `isolate-branch.sh --porcelain` at isolate
  time. Executing writes all five fields (Base ref is the exact ref — critical when
  remotes share branch names); Finishing READS them, never re-derives;
  `validate-transition.sh` and `squash-branch.sh` prefer Base ref over Base branch
  (Base branch stays for human readability and older summaries).

---

## Subagent Registry

All prompts are inline in [subagent-prompts.md](references/subagent-prompts.md). Prompts are self-contained — a subagent needs nothing else. When spawning, replace `<task-dir>` in the prompt with the real path. Look up the prompt by role:

| Role | Used in | Purpose |
|---|---|---|
| Discovery | Brainstorming (Big) | codebase discovery → `context/brief.md` |
| Plan Drafter | Planning (Big) | `plans/plan-v1.md` |
| Plan Reviewer | Planning (Big) | `reviews/plan-review.md` |
| Implementer | Executing (Big) | TDD implementation |
| Implementation Reviewer | Executing (Big) | `reviews/implementation-review.md` |
| Debugger | Debugging (Big) | diagnosis report |
| Test Runner | Finishing | pre-integration test run |
| Integrator | Finishing | merge + verify |
