---
name: powerflow-brainstorming
description: Load first for features, refactors, and greenfield work. Clarifies vague requests, classifies the task Small or Big, produces the Context Brief with cited facts, and confirms scope or approach with the user before planning.
---

# Phase 1: Powerflow Brainstorming

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (exit 2/3 → ask the user: resume, reuse, or new slug).
- Read `<task-dir>/summary.md` first if it exists.
- Announce: `"I'm using the powerflow-brainstorming skill to explore requirements."`

## 1. Clarify Vague Requests

If the request is vague, exploratory, or greenfield (no paths, fewer than 2 concrete acceptance criteria, phrased as a question), ask 2–3 clarifying questions first. Restate the goal in one sentence and confirm scope before discovery. Do not run any separate ideation flow.

## 2. Classify

Classify the task **Small or Big** using [complexity-rubric.md](../using-powerflow/references/complexity-rubric.md). If uncertain, classify Big.

## 3. Discovery

- **Small**: perform light discovery directly — search and read what you need, then write `brief.md` yourself.
- **Big**: spawn a subagent using the **Discovery** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). Once it completes, read `<task-dir>/context/brief.md` to confirm classification and facts.

### Brief Format (`<task-dir>/context/brief.md`)

1. Request Summary
2. Classification (Small/Big + one-line reason)
3. Facts — each with `file:line` citation
4. Assumptions — each marked `ASSUMPTION`
5. Constraints & Risks (Big only)
6. Approach (Big only, after user selection; mark overrides `[OVERRIDE BY USER]`)

**Evidence gate**: every claim carries a label (FACT or ASSUMPTION). No bare claims — per [global-epistemology.md](../using-powerflow/references/global-epistemology.md).

## 4. Checkpoint with the User

- **Small**: present the classification, facts, and scope boundaries. Ask the user to confirm the scope or adjust it.
- **Big (Checkpoint A)**: present constraints, risks, and 2–3 approaches with pros/cons/tradeoffs. Ask the user to pick an approach or propose another. Record the decision verbatim in `summary.md` (per the summary.md protocol in `using-powerflow/SKILL.md`). Mark any override `[OVERRIDE BY USER]` in the brief.

## 5. Handoff

1. Update `summary.md`: phase done, output path, user decisions verbatim with date, next phase (Planning).
2. Proceed to [powerflow-planning](../powerflow-planning/SKILL.md). Do not implement anything here.

## Non-Negotiable Behaviors

- **Classification is mandatory** before planning.
- **Brief persisted first**: the brief must be on disk and verified before transitioning to planning.
- **No bare claims**: every claim in the brief is FACT (with citation) or ASSUMPTION.
- **Big tasks**: discovery runs in a subagent, never in the orchestrator session.
