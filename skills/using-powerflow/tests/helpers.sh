#!/usr/bin/env bash
# Shared helpers for Powerflow fixture tests (plain bash + temp repos, no bats).
# Source from each test file: helpers.sh is at skills/using-powerflow/tests/helpers.sh
# shellcheck disable=SC2145

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL $1 -- $2"; }

assert_exit() { # assert_exit <name> <expected> <actual>
  if [ "$3" -eq "$2" ]; then pass "$1"; else fail "$1" "expected exit $2, got $3"; fi
}

assert_contains() { # assert_contains <name> <haystack> <needle>
  if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "output did not match /$3/"; fi
}

assert_not_contains() { # assert_not_contains <name> <haystack> <needle>
  if printf '%s' "$2" | grep -Eq "$3"; then fail "$1" "output unexpectedly matched /$3/"; else pass "$1"; fi
}

make_temp_repo() { # make_temp_repo -> echoes path; caller: TMP=$(make_temp_repo)
  local tmp
  tmp=$(mktemp -d)
  git init -b main -q "$tmp"
  git -C "$tmp" config user.email "test@example.com"
  git -C "$tmp" config user.name "Test"
  git -C "$tmp" commit -q --allow-empty -m "init"
  echo "$tmp"
}

commit_file() { # commit_file <repo> <path> <content> <message>
  printf '%s' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
}

summary_of() { # summary_of -> prints PASS/FAIL totals; exits non-zero on failure
  echo "--- $PASS_COUNT passed, $FAIL_COUNT failed ---"
  [ "$FAIL_COUNT" -eq 0 ]
}
