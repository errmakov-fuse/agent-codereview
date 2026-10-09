#!/usr/bin/env bash
# Runs scripts/classify.jq over the made-up PRs in classify_cases.json and
# compares the result with what each case should produce.
#
# The filter runs in gh's own jq, as it does in production, so this needs `gh`
# to be logged in. It makes one harmless API call per check and reads nothing from it.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTS/../scripts"
SKIP='["S.Y.S.T.E.M","do not review"]'

classify() {
  local dismissed="$1" skip="$2" drafts="$3"
  gh api user --jq "[\"me-new\",\"me-old\"] as \$me | [\"mate\"] as \$watched | $skip as \$skip_keywords
    | $drafts as \$review_drafts | $dismissed as \$rereview_dismissed
    | $(cat "$TESTS/classify_cases.json") | $(cat "$SCRIPTS/classify.jq")"
}

#  1 mine, nobody requested or reviewed              10 watched, never reviewed
#  2 mine, reviewer requested                        11 watched draft, nobody requested
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
#
# Title keywords (cases 1-41 and 60-65 have no title unless noted):
# 50 watched, keyword in the title                   51 watched, keyword in another case
# 52 mine, keyword in the title                      53 watched, changes requested and moved, keyword
# 54 watched, the keyword without its dots           55 watched, a keyword with spaces, another case
#
# Drafts from a watched author, and one of mine:
# 60 draft, my review requested                      61 draft, someone else requested
# 62 draft, my review requested, keyword in title    63 draft, changes requested and moved, not requested
# 64 draft, changes requested and moved, re-requested 65 my own draft
expected_ready="MINE 1
MINE 4
THEIRS 10
THEIRS 13
REREVIEW 22 h2 rerequested h1
REREVIEW 30 h2 changes_requested h1
REREVIEW 32 h2 changes_requested h1
REREVIEW 34 h2 changes_requested h1
REREVIEW 35 h2 changes_requested unknown"

expected_requested_drafts="THEIRS 60
REREVIEW 64 h2 rerequested h1"

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
  "$expected_ready
REREVIEW 40 h2 dismissed h1
THEIRS 54
$expected_requested_drafts" "$(classify true "$SKIP" false)"

check "dismissed approvals are left alone when the switch is off" \
  "$expected_ready
THEIRS 54
$expected_requested_drafts" "$(classify false "$SKIP" false)"

check "with no skip keywords the titled PRs are classified like any other" \
  "$expected_ready
THEIRS 50
THEIRS 51
MINE 52
REREVIEW 53 h2 changes_requested h1
THEIRS 54
THEIRS 55
THEIRS 60
THEIRS 62
REREVIEW 64 h2 rerequested h1" "$(classify false "[]" false)"

check "with REVIEW_DRAFTS on, a watched author's drafts are classified like ready PRs" \
  "MINE 1
MINE 4
THEIRS 10
THEIRS 11
THEIRS 13
REREVIEW 22 h2 rerequested h1
REREVIEW 30 h2 changes_requested h1
REREVIEW 32 h2 changes_requested h1
REREVIEW 34 h2 changes_requested h1
REREVIEW 35 h2 changes_requested unknown
THEIRS 54
THEIRS 60
THEIRS 61
REREVIEW 63 h2 changes_requested h1
REREVIEW 64 h2 rerequested h1" "$(classify false "$SKIP" true)"

exit "$failed"
