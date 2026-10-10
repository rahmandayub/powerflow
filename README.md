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

### Via `skills` CLI (recommended)

Install with the [open agent skills CLI](https://github.com/vercel-labs/skills) — no manual copying needed. It auto-detects your agent (Codex, Claude Code, opencode, Cursor, and 75+ more) and links the skills to the right directory.

```bash
# Install all 6 skills (non-interactive, all agents)
npx skills add rahmandayub/powerflow-skills --all

# Or install interactively (pick scope, agents, and skills)
npx skills add rahmandayub/powerflow-skills

# Install to your user directory so every project can use them
npx skills add rahmandayub/powerflow-skills --all -g
```

Useful variants:

```bash
# Preview available skills without installing
npx skills add rahmandayub/powerflow-skills --list

# Install specific skills only (always include using-powerflow — it's the entry router)
npx skills add rahmandayub/powerflow-skills --skill using-powerflow --skill powerflow-planning

# Install to specific agents only
npx skills add rahmandayub/powerflow-skills --all -a codex -a claude-code -a opencode
```

Project scope (default) installs to `./<agent>/skills/` so the suite is committed with your project and shared with the team. Global scope (`-g`) installs to `~/<agent>/skills/` for use across all projects.

### Manual install

If your harness isn't supported by the CLI, copy the `skills/` directory (or individual skill folders) into your agent's skills directory:

```bash
# Codex / Claude Code style
cp -r skills/* ~/.agents/skills/
```

## Core Concepts

- **Phase gating** — every phase requires a concrete artifact (`brief.md`, `plan-final.md`, verified changes) before the next phase starts.
- **Small/Big classification** — Small tasks are handled directly by the orchestrator; Big tasks are delegated to subagents for discovery, planning, implementation, and review.
- **Evidence rule** — every claim is labeled `FACT` (with `file:line`) or `ASSUMPTION`; bare claims are rewritten.
- **Task directory protocol** — state lives in `.powerflow/YYYY-MM-DD-HHMM-<task-slug>/`; `summary.md` is the single source of truth, written at the end of each phase and read at the start of the next.
- **Subagent registry** — all prompts are self-contained and inline in `using-powerflow/references/subagent-prompts.md`.

## License

MIT
