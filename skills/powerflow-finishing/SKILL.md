---
name: powerflow-finishing
description: Load when implementation is complete and verified. Offers commit squashing, runs pre-integration tests, presents integration options (merge, push & PR, keep, discard), and cleans up Powerflow branches and worktrees.
---

# Phase 4: Powerflow Finishing

## Before You Start

- Read `<task-dir>/summary.md` — it records the branch and phase state.
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
   - **Option 1**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --message "<clean message>"` (add `--base-branch <original>` if base is not main/master)
   - **Option 2**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --uncommitted` (add `--base-branch <original>` if base is not main/master)
   - **Option 3**: keep the micro-commits as-is.

## 2. Pre-Integration Verification

Before presenting integration choices, verify that the work is completely healthy on the current branch:

- **Small**: run the full test suite directly in the orchestrator.
- **Big**: spawn a subagent using the **Test Runner** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md).

Record results to `<task-dir>/executions/pre-integration-test-run.log`. If tests fail: STOP and present the failure summary to the user. Do not proceed to integration until resolved.

## 3. Environment & Base Branch Detection

1. Determine the original base branch (from `<task-dir>/summary.md`, or check upstream/default branch e.g. `main`/`master`/`develop`):
   ```bash
   ORIGINAL_BRANCH=$(git merge-base HEAD main 2>/dev/null && echo "main" || echo "master")
   ```
2. Determine if the session runs in a Git worktree:
   ```bash
   GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
   GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
   ```

## 4. Presentation of Options

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

## 5. Execution of Choice

- **Option 1 (Merge locally)**:
  - If working on a `powerflow/<slug>` branch:
    1. Ensure changes are committed.
    2. Checkout `<original_branch>` (from `summary.md` or detected base).
    3. Run fast-forward merge or spawn an **Integrator** subagent:
       ```bash
       git checkout <original_branch>
       git merge --ff-only powerflow/<task-slug> || git merge powerflow/<task-slug>
       git branch -d powerflow/<task-slug>
       ```
    4. Run verification tests on merged result.
    5. On success, proceed to worktree cleanup (Section 6) if in a worktree.
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
    1. Checkout the base branch (`git checkout <base-branch>`).
    2. Delete the feature branch (`git branch -D <feature-branch>`).
    3. Remove the worktree (Section 6) if applicable.

## 6. Worktree Cleanup

If Option 1 or 4 was chosen and the session runs in an ephemeral worktree under `.worktrees/` or `worktrees/`:

1. `cd` to the main repository root:
   ```bash
   MAIN_ROOT=$(git -C "$(git rev-parse --git-common-dir)/.." rev-parse --show-toplevel)
   cd "$MAIN_ROOT"
   ```
2. Remove the worktree:
   ```bash
   git worktree remove "$WORKTREE_PATH"
   git worktree prune
   ```

## 7. Closeout

Update `summary.md`: phase done, integration choice & result, task complete.
