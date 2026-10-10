---
name: powerflow-finishing
description: Load when implementation is complete and verified. Offers commit squashing, runs pre-integration tests, presents integration options (merge, push & PR, keep, discard), and cleans up Powerflow branches and worktrees.
---

# Phase 4: Powerflow Finishing

## Before You Start

- Read `<task-dir>/summary.md` — it records the Git State (Base branch/SHA, task branch) and phase state.
- Run the transition gate before anything else:
  `bash <skills-root>/using-powerflow/scripts/validate-transition.sh --task-dir <task-dir> --from executing --to finishing`
  On FAIL: STOP and fix (re-review, re-test at current HEAD, or file a scope-change) — do not squash, merge, or delete.
- Announce: `"I'm using the powerflow-finishing skill to integrate this work."`

## 1. Git History Review & Squash Offer (required first)

Do NOT skip this step and do NOT present the integration options before the squash decision.

1. Show the micro-commit list (`git log`) to the user.
2. Ask the user verbatim:
   > "I have detected developmental micro-commits on this branch. How would you like to handle them before integrating?
   > 1. Squash into a single clean commit
   > 2. Convert into uncommitted changes (soft reset without committing)
   > 3. Keep all micro-commits intact"
3. Execute the choice:
   - **Option 1**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --message "<clean message>" --base-branch "<Base branch from summary.md Git State>"` (or `--task-dir <task-dir>` instead of `--base-branch`; the base is read from Git State, never guessed)
   - **Option 2**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --uncommitted --base-branch "<Base branch from summary.md Git State>"` (or `--task-dir <task-dir>`)
   - **Option 3**: keep the micro-commits as-is.
   - The script refuses on detached HEAD (exit 2) and on a dirty tree (exit 4) unless `--allow-dirty` is passed explicitly. Untracked files alone do not block.

## 2. Pre-Integration Verification (tiered)

Run tiers in order on the current branch; STOP on the first red tier:

- **Tier 1 — smoke**: fastest meaningful check (build/lint/import + one happy-path
  command taken from the plan).
- **Tier 2 — affected**: tests covering the files in
  `git diff --name-only <Base-SHA>...HEAD` (Base SHA from `summary.md` Git State).
- **Tier 3 — full suite**: the complete project test suite.

- **Small**: orchestrator runs the tiers directly in the same `COMMAND`/`SHA`/`EXIT`
  log format below.
- **Big**: spawn a subagent using the **Test Runner** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md).

Policy: always run Tier 1+2; Tier 3 is required before Option 1 (merge) or Option 2
(PR). A Low-complexity/Low-risk task may record a user waiver for Tier 3 on the
pre-merge result only — never skip Tier 1+2.

Log every tier to `<task-dir>/executions/pre-integration-test-run.log` with a
validator-parseable header per tier:

```
TIER: <smoke|affected|full>
COMMAND: <exact command>
SHA: <git rev-parse HEAD>
EXIT: <0|non-zero>
```

followed by the output tail. If any tier fails: STOP and present the failure summary
to the user. Do not proceed to integration until resolved.

## 3. Environment & Base Branch Detection

1. Read the base from `<task-dir>/summary.md` Git State (`Base branch`, `Base SHA`).
   Verify with:
   ```bash
   git show-ref --verify --quiet "refs/heads/<Base branch>"
   git merge-base --is-ancestor <Base-SHA> HEAD
   ```
   If Git State is missing or verification fails: STOP and ask the user. Never fall
   back to guessing `main`/`master`.
2. Detect detached HEAD:
   ```bash
   git rev-parse --abbrev-ref HEAD   # prints HEAD when detached
   git symbolic-ref -q HEAD || echo detached
   ```
   On a branch use the Standard menu; when detached use the Detached HEAD menu only.
3. Determine if the session runs in a Git worktree:
   ```bash
   GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
   GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
   ```

## 4. Preflight (before any destructive op)

Before merge (Option 1), discard (Option 4), or worktree removal (Section 7):

- Working tree clean for tracked files (`git status --porcelain`), or a user waiver
  recorded verbatim in `summary.md`.
- Not detached, unless using the Detached HEAD menu.
- `pre-integration-test-run.log` exists with a Tier 3 (or waived-tier) PASS at the
  tested SHA, and the tested SHA equals current HEAD.
- Save a recovery line to `summary.md` and `<task-dir>/executions/merge-verification.log`:
  `Pre-integration HEAD: <SHA> on <branch>`.
  Recover with `git branch <task-branch> <SHA>` if the ref is lost.

## 5. Presentation of Options

### Standard Branch or Named-Branch Worktree

```
Implementation complete and verified. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

### Detached HEAD (Externally Managed Workspace)

```
Implementation complete and verified. You're on a detached HEAD.

1. Push as a new branch and create a Pull Request
2. Keep as-is (I'll handle it later)
3. Discard this work

Which option?
```

## 6. Execution of Choice

- **Option 1 (Merge locally)**:
  - If working on a `powerflow/<slug>` branch:
    1. Run the Preflight (Section 4).
    2. Ensure changes are committed.
    3. Checkout `<Base branch>` (from `summary.md` Git State — never re-derived).
    4. Pull latest (or record "offline, skipped pull").
    5. Merge: `git merge --ff-only powerflow/<task-slug> || git merge powerflow/<task-slug>`.
       For complex merges, spawn an **Integrator** subagent instead — it executes the
       merge + verification; the orchestrator only coordinates choices. Never run two
       overlapping merges.
    6. Run tiered verification (Section 2) on the MERGED result.
    7. Only on success: delete the task branch (`git branch -d powerflow/<task-slug>`),
       then proceed to worktree cleanup (Section 7) if in a worktree.
    8. On verification failure: STOP, keep the task branch, present the failure.
       The branch must still exist — never delete before verification passes.
- **Option 2 (Push & PR)**:
  - Run `git push -u origin <feature-or-powerflow-branch>`.
  - Provide the push status / PR creation link to the user.
  - Do NOT delete the branch or clean up the worktree (keep it for iterating on PR feedback).
- **Option 3 (Keep as-is)**:
  - Announce `"Keeping branch <name>. Worktree preserved."`
  - Do NOT delete the branch or worktree.
- **Option 4 (Discard)**:
  - Ask for explicit confirmation:
    > "This will permanently delete branch <name> and all changes. Type 'discard' to confirm."
  - Once confirmed:
    1. Run the Preflight (Section 4) and save the recovery SHA.
    2. Checkout the base branch (`git checkout <Base branch from Git State>`).
    3. Delete the feature branch (`git branch -D <feature-branch>`).
    4. Remove the worktree (Section 7) if applicable.

## 7. Worktree Cleanup

If Option 1 or 4 was chosen and the session runs in an ephemeral worktree under `.worktrees/` or `worktrees/`:

1. Derive the worktree path (never assume a variable is set):
   ```bash
   WORKTREE_PATH=$(git rev-parse --show-toplevel)
   git worktree list --porcelain
   ```
2. Refuse to remove unless the path is under `.worktrees/` or `worktrees/`, the tree
   is clean, and branch identity matches — without explicit user confirmation otherwise.
3. `cd` to the main repository root:
   ```bash
   MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
   cd "$MAIN_ROOT"
   ```
4. Remove the worktree (only after post-merge verification passed for Option 1):
   ```bash
   git worktree remove "$WORKTREE_PATH"
   git worktree prune
   ```

## 8. Closeout

Update `summary.md`: phase done, integration choice & result, task complete.
