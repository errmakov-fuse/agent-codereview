#!/usr/bin/env bash
# Runs scripts/pr_updates.js over the made-up PR payloads in
# fixtures/pr_updates and compares the two output lines (newest time, summary)
# with what each case should produce.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TESTS/../scripts"
FIXTURES="$TESTS/fixtures/pr_updates"
export IGNORE="errmakov-fuse errmakov dependabot[bot]"

updates() {
  SINCE="$2" node "$SCRIPTS/pr_updates.js" < "$FIXTURES/$1.json"
}

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

# $(...) drops trailing newlines, so the "no news" cases (a dash, then an empty
# line) are compared as "-" here and the line count is checked on its own.
check "a review and its comments are counted, my own comment is ignored" \
  "2026-10-29T17:41:00Z
a review requesting changes and 2 comments from samrent-infuse" \
  "$(updates review_and_comments "")"

check "items at or before SINCE are dropped" \
  "2026-10-29T17:41:00Z
2 comments from samrent-infuse" \
  "$(updates review_and_comments "2026-10-29T17:40:05Z")"

check "an item exactly at SINCE is dropped" "-" \
  "$(updates review_and_comments "2026-10-29T17:41:00Z" | head -n 1)"

check "only my own activity gives a dash, whatever the login case" "-" \
  "$(updates own_only "")"

check "the output is always exactly two lines" "2" \
  "$(updates own_only "" | wc -l | tr -d ' ')"

check "an approval and a comment from two people" \
  "2026-10-29T10:05:00Z
an approval and 1 comment from samrent-infuse and romanvasilenko-infuse" \
  "$(updates approval_two_people "")"

check "an empty COMMENTED review adds nothing beyond its comment" \
  "2026-10-29T11:00:06Z
1 comment from samrent-infuse" \
  "$(updates empty_commented_review "")"

check "invalid JSON prints a dash and an empty line and exits 2" \
  "-

exit=2" \
  "$(echo 'not json' | node "$SCRIPTS/pr_updates.js" 2>/dev/null; echo "exit=$?")"

exit "$failed"
