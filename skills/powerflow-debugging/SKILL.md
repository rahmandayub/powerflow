---
name: powerflow-debugging
description: Load for bug fixes, failing tests, and crashes — as an entry point or during execution. Produces an evidence-based Diagnosis Report with fix scope and classification, without writing any code.
---

# Powerflow Debugging

## Before You Start

- Task directory: `.powerflow/YYYY-MM-DD-<task-slug>/`. If it does not exist, create it with `bash <skills-root>/powerflow-brainstorming/scripts/init-task-dir.sh --task-slug <slug>` (add `--no-gitignore` to skip `.gitignore` mutation; exit 2/3 → ask the user). Announce explicitly if `.gitignore` was created or modified.
- Read `<task-dir>/summary.md` first if it exists.
- Announce: `"I'm using the powerflow-debugging skill to analyze this failure."`

## 1. Investigate

Classify the failure **Small or Big** using [complexity-rubric.md](../using-powerflow/references/complexity-rubric.md):

- **Small**: investigate directly — reproduce, trace the call chain, inspect state.
- **Big**: spawn a subagent using the **Debugger** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md).

## 2. Diagnosis Report

Write the findings to `<task-dir>/executions/diagnostics/<step-name>.md` (e.g. `step-3-auth-failure.md`). The report must contain:

1. **Incident Summary** — symptoms and impact
2. **Investigative Trail** — checks performed, tagged `file:line` or `log:timestamp`
3. **Root Cause** — verified location and mechanism
4. **Blast Radius** — affected files/components
5. **Recommended Fix Scope** — exact files to modify + plain-text fix description. **No code blocks.**
6. **Unverified Hypotheses** — any remaining uncertainty, marked explicitly
7. **Classification** — Small/Big (required for planning handoff)

## 3. Handoff

Update `summary.md`: phase done, diagnosis report path, next phase (Planning — with the Diagnosis Report as context).

## 4. Non-Negotiable Behaviors

- **Evidence only**: never state a root cause without direct codebase or log evidence.
- **Hypotheses stay hypotheses**: unverified theories are marked as such.
- **No code generation**: the report never contains code or draft implementation — code belongs to planning and executing.
