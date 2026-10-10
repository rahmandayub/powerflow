#!/usr/bin/env bash
set -uo pipefail
# Doc-contract guard: verifies that the operational contract stated in the
# SKILL.md files still contains the key phrases and ORDERING the fixtures and
# scripts rely on. Fixtures prove Git behavior; this suite proves the docs
# that instruct the agent have not drifted from that behavior.
# Grep-based by design: cheap and stable, not a Markdown parser.
HERE=$(cd "$(dirname "$0")" && pwd)
SKILLS_ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=helpers.sh
source "$HERE/helpers.sh"

FIN="$SKILLS_ROOT/powerflow-finishing/SKILL.md"
PLAN="$SKILLS_ROOT/powerflow-planning/SKILL.md"
EXEC="$SKILLS_ROOT/powerflow-executing/SKILL.md"
USE="$SKILLS_ROOT/using-powerflow/SKILL.md"

line_of() { # line_of <file> <fixed-string> -> first 1-based line number, or empty
  grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1 || true
}

section_text() { # section_text <file> <start-fixed> <end-fixed> -> text between the two markers (inclusive of start, exclusive of end)
  awk -v s="$2" -v e="$3" '
    !in_sec && index($0, s) { in_sec = 1 }
    in_sec && index($0, e) && !index($0, s) { exit }
    in_sec { print }
  ' "$1" 2>/dev/null || true
}

line_in() { # line_in <text> <fixed-string> -> first 1-based line number within <text>, or empty
  printf '%s\n' "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1 || true
}

assert_before() { # assert_before <name> <file> <needle1> <needle2> (1 must appear before 2)
  local n1 n2
  n1=$(line_of "$2" "$3")
  n2=$(line_of "$2" "$4")
  if [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ]; then
    pass "$1"
  else
    fail "$1" "'$3' (line ${n1:-missing}) must appear before '$4' (line ${n2:-missing}) in $2"
  fi
}

order_in_section() { # order_in_section <file> <start> <end> <needle1> <needle2> -> 0 if 1 precedes 2 inside the section
  local sec n1 n2
  sec=$(section_text "$1" "$2" "$3")
  [ -n "$sec" ] || return 2
  n1=$(line_in "$sec" "$4")
  n2=$(line_in "$sec" "$5")
  [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ]
}

assert_before_in_section() { # assert_before_in_section <name> <file> <start> <end> <needle1> <needle2>
  # Ordering is checked INSIDE the [start, end) section only, so identical
  # phrases elsewhere in the file cannot cause a false pass.
  if order_in_section "$2" "$3" "$4" "$5" "$6"; then
    pass "$1"
  else
    fail "$1" "inside '$3' -> '$4' of $2: '$5' must appear before '$6'"
  fi
}

assert_has() { # assert_has <name> <file> <fixed-string>
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    pass "$1"
  else
    fail "$1" "$2 no longer contains: $3"
  fi
}

# --- finishing: worktree merge contract --------------------------------------

assert_has "doc-merge-owner-precheck-symbolic" "$FIN" 'symbolic-ref -q HEAD'
assert_has "doc-merge-owner-precheck-branch" "$FIN" 'rev-parse --abbrev-ref HEAD'
assert_has "doc-merge-owner-git-C" "$FIN" 'git -C "$OWNER"'
assert_has "doc-merge-precheck-never-naked-git" "$FIN" 'never bare `git` from the task worktree'
OPT1_START='- **Option 1 (Merge locally)**:'
OPT1_END='- **Option 2 (Push & PR)**:'
assert_before_in_section "doc-order-checkout-before-sync" "$FIN" "$OPT1_START" "$OPT1_END" 'Locate the worktree that owns the integration branch' 'Sync the integration branch'
assert_before_in_section "doc-order-sync-before-merge" "$FIN" "$OPT1_START" "$OPT1_END" 'Sync the integration branch' 'Merge the task branch'
assert_before_in_section "doc-order-verify-before-cleanup" "$FIN" "$OPT1_START" "$OPT1_END" 'Run tiered verification (Section 2) on the MERGED result' 'Clean up the worktree that was holding the task branch'
assert_before_in_section "doc-order-cleanup-before-branch-delete" "$FIN" "$OPT1_START" "$OPT1_END" 'Clean up the worktree that was holding the task branch' 'Then delete the task branch'

# --- finishing: pull contract -------------------------------------------------

assert_has "doc-pull-ff-only" "$FIN" 'pull --ff-only'
assert_has "doc-pull-failure-stops" "$FIN" 'STOP and report'
assert_has "doc-pull-not-consent" "$FIN" 'NOT consent to skip'
assert_has "doc-pull-offline-recorded" "$FIN" 'offline, skipped pull'
assert_has "doc-pull-no-upstream-decision" "$FIN" 'NO upstream'

# --- finishing: integration branch resolution ---------------------------------

assert_has "doc-resolver-referenced" "$FIN" 'resolve-integration-branch.sh'
assert_has "doc-resolver-no-remote-checkout" "$FIN" 'never `git checkout <Base ref>`'
assert_has "doc-preflight-referenced" "$FIN" 'validate-transition.sh --task-dir <task-dir> --preflight'

# --- git state protocol -------------------------------------------------------

assert_has "doc-summary-base-ref-field" "$USE" '- Base ref:'
assert_has "doc-summary-base-ref-preferred" "$USE" 'Base ref'
assert_has "doc-summary-base-ref-ambiguous" "$USE" 'remotes share branch names'

# --- scope-change contract ----------------------------------------------------

assert_has "doc-scope-request-block" "$PLAN" '## Request SC-001'
assert_has "doc-scope-amendment-names-paths" "$PLAN" 'EVERY added path'
assert_has "doc-scope-cumulative" "$PLAN" 'CUMULATIVE'
assert_has "doc-scope-latest-blocks" "$PLAN" 'LATEST request must still be complete'
assert_has "doc-exec-scope-cumulative" "$EXEC" 'cumulative'

# --- self-tests: section scoping is not fooled by out-of-section copies -------

SELF_DOC=$(mktemp)
cat > "$SELF_DOC" <<'EOF'
alpha appears early, OUTSIDE the tested section
## OPTION
beta comes first inside
alpha comes second inside
## NEXT
EOF
# Out-of-section "alpha" must be ignored: inside, beta precedes alpha -> FAIL.
order_in_section "$SELF_DOC" '## OPTION' '## NEXT' 'alpha' 'beta'; CODE=$?
assert_exit "selftest-section-ignores-outside-copy" 1 "$CODE"
# Correct order inside the same section -> PASS.
order_in_section "$SELF_DOC" '## OPTION' '## NEXT' 'beta' 'alpha'; CODE=$?
assert_exit "selftest-section-correct-order" 0 "$CODE"
# Missing section -> distinct failure code (2), never a silent pass.
order_in_section "$SELF_DOC" '## MISSING' '## NEXT' 'beta' 'alpha'; CODE=$?
assert_exit "selftest-missing-section" 2 "$CODE"
rm -f "$SELF_DOC"

summary_of
