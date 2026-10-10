---
name: powerflow-finishing
description: Load when implementation is complete and verified. Offers commit squashing, runs pre-integration tests, presents integration options (merge, push & PR, keep, discard), and cleans up Powerflow branches and worktrees.
---

# Phase 4: Powerflow Finishing

## Before You Start

- Read `<task-dir>/summary.md` — it records the Git State (Base ref/branch/SHA, task branch) and phase state.
- Run the transition gate before anything else:
  `bash <skills-root>/using-powerflow/scripts/validate-transition.sh --task-dir <task-dir> --from executing --to finishing`
  On FAIL: STOP and fix (re-review, scope-change completion, or git state) — do not squash, merge, or delete.
  This gate intentionally does NOT require the pre-integration test log (it is
  written in Section 2, after the gate). Before any destructive op (merge,
  discard, worktree removal), run the preflight instead:
  `bash <skills-root>/using-powerflow/scripts/validate-transition.sh --task-dir <task-dir> --preflight`
  On FAIL: STOP and run the missing tiers at current HEAD first.
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
(PR). A Small task may record a user waiver for Tier 3 in
`<task-dir>/reports/tier3-waiver.md` — it must hold a `User decision:` line with
a YYYY-MM-DD date, a waiver verb, a Tier 3 reference, and a parenthesized reason
(e.g. `User decision: 2026-01-01 waive Tier 3 full suite (reason: trivial
one-file change, Tier 1+2 green).`) — never skip Tier 1+2, and Big tasks cannot
waive Tier 3. The `--preflight` mode of `validate-transition.sh` enforces exactly
this (Tier 1+2 PASS at HEAD, plus Tier 3 PASS at HEAD or a valid waiver), and
also verifies the current checkout is the recorded Task branch.

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

## 3. Environment & Integration Branch Resolution

Two distinct concepts — never conflate them:

- **Base ref**: the exact integration source recorded at isolate time
  (`Base ref` in Git State, e.g. `upstream/main`). Used for merge-base,
  diff-scope, and squash. Read-only.
- **Integration branch**: the LOCAL branch that receives the merge. Merge and
  verification MUST land on a named local branch — never on a detached HEAD.

1. Read the base from `<task-dir>/summary.md` Git State (`Base ref` preferred,
   `Base branch` fallback, `Base SHA`). Verify with:
   ```bash
   git rev-parse --verify --quiet "<Base ref>"
   git merge-base --is-ancestor <Base-SHA> HEAD
   ```
   If Git State is missing or verification fails: STOP and ask the user. Never fall
   back to guessing `main`/`master`.
2. Resolve the integration branch (refuses detached checkout):
   ```bash
   bash <skills-root>/powerflow-finishing/scripts/resolve-integration-branch.sh --task-dir <task-dir> --porcelain
   ```
   - Exit 0 → `INTEGRATION_BRANCH=<local branch>`; checkout THAT branch for
     Options 1/4 below — never `git checkout <Base ref>` when the ref is
     remote-tracking (that detaches HEAD and the merge lands nowhere).
   - Exit 3 → Base ref is remote-tracking with no local branch tracking it:
     STOP and ask the user to create one
     (`git checkout -b <name> --track <Base ref>`) or pick the integration
     branch explicitly. Do NOT proceed on detached HEAD.
   - Exit 1/2 → unknown ref / unreadable summary: STOP and ask the user.
3. Detect detached HEAD:
   ```bash
   git rev-parse --abbrev-ref HEAD   # prints HEAD when detached
   git symbolic-ref -q HEAD || echo detached
   ```
   On a branch use the Standard menu; when detached use the Detached HEAD menu only.
4. Determine if the session runs in a Git worktree:
   ```bash
   GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
   GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
   ```

## 4. Preflight (before any destructive op)

Before merge (Option 1), discard (Option 4), or worktree removal (Section 7),
run the preflight gate (it replaces the manual checklist below):

```bash
bash <skills-root>/using-powerflow/scripts/validate-transition.sh --task-dir <task-dir> --preflight
```

On FAIL: STOP and fix (run the missing tiers at current HEAD, commit/stash, or
record a Tier 3 waiver for Small tasks) — do not proceed. The preflight checks:

- Tier 1 (smoke) and Tier 2 (affected) PASS at current HEAD in
  `pre-integration-test-run.log` (never waivable).
- Tier 3 (full) PASS at current HEAD, or a dated waiver in
  `<task-dir>/reports/tier3-waiver.md` (Small tasks only).
- Working tree clean for tracked files, or a user waiver recorded verbatim in
  `summary.md`.
- On a branch (detached HEAD uses the Detached HEAD menu only).
- Additionally save a recovery line to `summary.md` and `<task-dir>/executions/merge-verification.log`:
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
    3. Resolve the integration branch (Section 3, step 2).
    4. Locate the merge:
       - **Main checkout** (current worktree already on, or free to checkout,
         the integration branch): checkout the integration branch there,
         confirm attached (`git symbolic-ref -q HEAD`), pull latest (or record
         "offline, skipped pull"; pull follows the branch's own tracking —
         do not assume `origin`), then merge.
       - **Task worktree** (integration branch checked out in ANOTHER
         worktree, so this worktree cannot take it): do NOT checkout — run
         the merge in the worktree that owns the integration branch.
         First pull there explicitly (before merging):
         ```bash
         MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
         git -C "$MAIN_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}'  # upstream present?
         git -C "$MAIN_ROOT" pull --ff-only    # or record "offline, skipped pull" when no upstream/offline
         git -C "$MAIN_ROOT" merge --ff-only <task-branch> || git -C "$MAIN_ROOT" merge <task-branch>
         ```
         (Replace `$MAIN_ROOT` with the owning worktree's path from
         `git worktree list --porcelain` when the integration branch lives
         elsewhere. Verify there (step 6) — never here.)
    5. Merge: `git merge --ff-only powerflow/<task-slug> || git merge powerflow/<task-slug>`
       (in the worktree from step 4).
       For complex merges, spawn an **Integrator** subagent instead — it executes the
       merge + verification; the orchestrator only coordinates choices. Never run two
       overlapping merges.
    6. Run tiered verification (Section 2) on the MERGED result (in the same
       worktree as the merge).
    7. Only on success, in this order:
       1. Clean up the worktree that was holding the task branch (Section 7) —
          the task branch cannot be deleted while a worktree has it checked
          out. If the merge worktree is ephemeral, remove it too.
       2. Then delete the task branch (`git branch -d powerflow/<task-slug>`,
          or `-D` when squash made it non-ancestor).
       In the main checkout (no worktree involved): delete the task branch
       directly.
    8. On verification failure: STOP, keep the task branch AND the worktree,
       present the failure. Never delete before verification passes.
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
    1. Run the Preflight (Section 4) and save the recovery SHA (branch name +
       SHA — the branch CANNOT be deleted while a worktree has it checked out).
    2. If the task branch is checked out in a worktree (this one or another):
       remove THAT worktree first (`git worktree remove <path>` from the main
       repo; `--force` only with a saved recovery SHA), THEN delete the branch
       (`git branch -D <feature-branch>`) from the main repository location.
       Never delete a branch out from under its worktree.
    3. If in the main checkout (no worktree holds either branch): checkout the
       integration branch (Section 3, step 2 — a local branch, never a
       remote-tracking ref), then delete the feature branch.
    4. Remove the worktree (Section 7) if applicable (already done in step 2
       when the worktree held the task branch).

## 7. Worktree Cleanup

If Option 1 or 4 was chosen and the session runs in an ephemeral worktree under
`.worktrees/` or `worktrees/` (Option 1 runs this BEFORE deleting the task
branch — a branch held by a worktree cannot be deleted; Option 4 already
removed the worktree in Section 6):

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
   Then, for Option 1, delete the task branch now that no worktree holds it.

## 8. Closeout

Update `summary.md`: phase done, integration choice & result, task complete.
