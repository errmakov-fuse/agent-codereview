#!/usr/bin/env bash
# Runs scripts/classify.jq over the made-up PRs in classify_cases.json and
# compares the result with what each case should produce.
#
# The filter runs in gh's own jq, as it does in production, so this needs `gh`
# to be logged in. It makes one harmless API call and reads nothing from it.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTS/../scripts"

classify() {
  local dismissed="$1"
  gh api user --jq "[\"me-new\",\"me-old\"] as \$me | [\"mate\"] as \$watched | $dismissed as \$rereview_dismissed
    | $(cat "$TESTS/classify_cases.json") | $(cat "$SCRIPTS/classify.jq")"
}

#  1 mine, nobody requested or reviewed              10 watched, never reviewed
#  2 mine, reviewer requested                        11 watched draft
#  3 mine, reviewed by someone else                  12 not a watched author
#  4 mine (old login), only my own comment           13 watched, reviewed by someone else only
#  5 mine, a team requested                          20 approved at head
#  6 mine, draft                                     21 approved, head moved, not re-requested
# 22 approved, head moved, re-requested              23 re-requested, head not moved
# 30 changes requested, head moved                   31 changes requested, head not moved
# 32 changes requested, then a thread reply at head  33 changes requested, later approved at head
# 34 changes requested from my old login             35 changes requested, reviewed commit gone
# 36 someone else requested changes, I approved      40 my approval dismissed, head moved
# 41 only a comment from me, head moved
expected_common="MINE 1
MINE 4
THEIRS 10
THEIRS 13
REREVIEW 22 h2 rerequested h1
REREVIEW 30 h2 changes_requested h1
REREVIEW 32 h2 changes_requested h1
REREVIEW 34 h2 changes_requested h1
REREVIEW 35 h2 changes_requested "

failed=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
    return
  fi
  failed=1
  echo "FAIL $name"
  echo "--- expected"
  echo "$expected"
  echo "--- actual"
  echo "$actual"
}

check "dismissed approvals are re-reviewed when the switch is on" \
  "$expected_common
REREVIEW 40 h2 dismissed h1" "$(classify true)"

check "dismissed approvals are left alone when the switch is off" \
  "$expected_common" "$(classify false)"

exit "$failed"
