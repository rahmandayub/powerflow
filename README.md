# Powerflow Skills

A structured, phase-gated workflow for AI coding agents. Powerflow turns vague requests into evidence-based plans, executes them with TDD discipline, and finishes with clean integration — all through a suite of composable skills.

> **Note:** This is a skill suite for agent harnesses that support skills (e.g., Codex, Claude Code, opencode). It is not a standalone CLI application.

## Skills

| Skill | Phase | Purpose |
|---|---|---|
| `using-powerflow` | Entry | Router for the suite. Establishes the phase workflow, Small/Big classification, evidence rule, and task directory protocol. Load first. |
| `powerflow-brainstorming` | 1 | Clarifies vague requests, classifies the task Small or Big, produces a Context Brief with cited facts, and confirms scope/approach with the user. |
| `powerflow-debugging` | 1 | For bug fixes, failing tests, and crashes. Produces an evidence-based Diagnosis Report without writing code. |
| `powerflow-planning` | 2 | Writes the implementation plan directly (Small) or drafts and reviews it via subagents (Big), ending with an approved `plan-final.md`. |
| `powerflow-executing` | 3 | Implements Small tasks directly, or delegates Big tasks to an Implementer subagent with TDD steps, then runs implementation review and verification. |
| `powerflow-finishing` | 4 | Offers commit squashing, runs pre-integration tests, presents integration options (merge, push & PR, keep, discard), and cleans up branches/worktrees. |

## Workflow

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

## Layout

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

## Installation

Copy the `skills/` directory (or individual skill folders) into your agent harness's skills directory. For example:

```bash
# Codex / Claude Code style
cp -r skills/* ~/.agents/skills/
```

## Core Concepts

- **Phase gating** — every phase requires a concrete artifact (`brief.md`, `plan-final.md`, verified changes) before the next phase starts.
- **Small/Big classification** — Small tasks are handled directly by the orchestrator; Big tasks are delegated to subagents for discovery, planning, implementation, and review.
- **Evidence rule** — every claim is labeled `FACT` (with `file:line`) or `ASSUMPTION`; bare claims are rewritten.
- **Task directory protocol** — state lives in `.powerflow/YYYY-MM-DD-<task-slug>/`; `summary.md` is the single source of truth, written at the end of each phase and read at the start of the next.
- **Subagent registry** — all prompts are self-contained and inline in `using-powerflow/references/subagent-prompts.md`.

## License

MIT
