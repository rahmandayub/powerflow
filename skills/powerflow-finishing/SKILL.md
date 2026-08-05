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
   - **Option 1**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --message "<clean message>"`
   - **Option 2**: `bash <skills-root>/powerflow-finishing/scripts/squash-branch.sh --uncommitted`
   - **Option 3**: keep the micro-commits as-is.
   - If the original branch (from `summary.md`) is not `main`/`master`/`develop`, add `--base-branch <original>` to the squash command.

## 2. Powerflow Branch Cleanup

If `summary.md` records a `powerflow/<slug>` branch:

1. Confirm the current branch is `powerflow/<task-slug>`.
2. Read the original branch from `summary.md` (if not recorded, use `main` or ask the user).
3. Ensure all changes are committed (stash if needed).
4. Run:
   ```bash
   git checkout <original_branch>
   git merge --ff-only powerflow/<task-slug> || echo "Non-fast-forward merge required. Manual integration needed."
   git branch -D powerflow/<task-slug>
   ```
5. If the merge fails (non-ff), present the situation and ask the user how to proceed (regular merge, rebase, or abort).
6. Update `summary.md` with the result. Proceed to Section 3 from `<original_branch>`.

## 3. Pre-Integration Verification

- **Small**: run the full test suite directly in the orchestrator.
- **Big**: spawn a subagent using the **Test Runner** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md).

Either way, record results to `<task-dir>/executions/pre-integration-test-run.log`. If tests fail: stop and present the failure summary to the user. Do not proceed to integration.

## 4. Environment Detection

1. Determine if the session runs in a Git worktree:
   ```bash
   GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
   GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
   ```
2. Determine the base branch (usually `main` or `master`):
   ```bash
   git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
   ```

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

- **Option 1 (Merge locally)**: spawn a subagent using the **Integrator** prompt from [subagent-prompts.md](../using-powerflow/references/subagent-prompts.md). On success, proceed to worktree cleanup (Section 7).
- **Option 2 (Push & PR)**: run `git push -u origin <feature-branch>`. Do NOT clean up the worktree (keep it for iterating on PR reviews).
- **Option 3 (Keep as-is)**: announce `"Keeping branch <name>. Worktree preserved."` Do NOT clean up.
- **Option 4 (Discard)**: ask for confirmation:
  > "This will permanently delete branch <name> and all changes. Type 'discard' to confirm."
  Once confirmed: remove the worktree (Section 7), then `git branch -D <feature-branch>`.

## 7. Worktree Cleanup

If Option 1 or 4 was chosen and the session runs in a worktree under `.worktrees/` or `worktrees/`:

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

## 8. Closeout

Update `summary.md`: phase done, integration result, task complete.
