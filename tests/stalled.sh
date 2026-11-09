#!/usr/bin/env bash
# Checks how poll.sh treats my stalled PR (scripts/stalled.sh): MY_PR_REVIEWER is
# requested again after every STALLED_AFTER_MINUTES of idle, where any review, or
# any push or comment by me, restarts the clock; the notification comes once per head.
#
# GitHub is stubbed: request_reviewer and author_activity_at are replaced. The
# activity filter itself runs in gh's own jq, as in production, so `gh` must be
# logged in; it makes one harmless API call per check and reads nothing from it.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_CODEREVIEW_STATE="$TMP/state"
# shellcheck source=/dev/null
. "$TESTS/../scripts/lib.sh"
# shellcheck source=/dev/null
. "$TESTS/../scripts/stalled.sh"
mkdir -p "$STATE_DIR"

REPO="Org/repo"
MY_LOGINS="me-new me-old"
MY_PR_REVIEWER="buddy"
STALLED_AFTER_MINUTES=30

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

# An ISO time this many minutes ago.
ago() {
  date -u -d "@$(($(date +%s) - $1 * 60))" +%FT%TZ
}

# The stubs record what they were asked to do.
ACTIVITY=""
ACTIVITY_FAILS=0
REQUEST_FAILS=0
request_reviewer() {
  echo "request $1 $2" >>"$TMP/calls"
  [ "$REQUEST_FAILS" -eq 0 ]
}
author_activity_at() {
  echo "activity $1" >>"$TMP/calls"
  [ "$ACTIVITY_FAILS" -eq 0 ] || return 1
  echo "$ACTIVITY"
}

# Clean state, the defaults above, and no dry run.
fresh() {
  rm -rf "$STATE_DIR" "$TMP/calls"
  mkdir -p "$STATE_DIR"
  touch "$STALLED" "$STALLED_TRIES" "$LOG" "$TMP/calls"
  ACTIVITY="" ACTIVITY_FAILS=0 REQUEST_FAILS=0
  STALLED_REREQUEST=true
  dry_run=0
}

calls() { cat "$TMP/calls"; }
logged() { sed 's/^[^ ]* //' "$LOG"; }

# --- Idle long enough: requested, reported once per head --------------------------
fresh
last=$(ago 31)
check "idle 31 minutes: the stalled line" "STALLED #90 buddy buddy" "$(handle_stalled 90 h1abcdef buddy "$last")"
check "idle 31 minutes: activity read, reviewer requested" "activity 90
request 90 buddy" "$(calls)"
check "idle 31 minutes: the head is recorded" "90@h1abcdef" "$(cat "$STALLED")"
check "idle 31 minutes: logged" "stalled #90 at h1abcde: idle since $last, last review by buddy at $last, requested buddy" "$(logged)"

# The next idle stretch: the last request is older than the last review.
: >"$TMP/calls"
: >"$LOG"
printf '90\t%s\n' "$(ago 32)" >"$STALLED_TRIES"
check "the same head, idle again: no second notification" "" "$(handle_stalled 90 h1abcdef buddy "$last")"
check "the same head, idle again: requested again" "activity 90
request 90 buddy" "$(calls)"
check "the same head, idle again: the head is recorded once" "90@h1abcdef" "$(cat "$STALLED")"
check "the same head, idle again: logged" "stalled #90 at h1abcde: idle since $last, last review by buddy at $last, requested buddy" "$(logged)"

: >"$TMP/calls"
printf '90\t%s\n' "$(ago 32)" >"$STALLED_TRIES"
check "a new head: notified again" "STALLED #90 buddy buddy" "$(handle_stalled 90 h2abcdef buddy "$last")"
check "a new head: recorded next to the old one" "90@h1abcdef
90@h2abcdef" "$(cat "$STALLED")"

# --- Not idle long enough ----------------------------------------------------------
fresh
check "last review 10 minutes ago: nothing" "" "$(handle_stalled 90 h1abcdef buddy "$(ago 10)")"
check "last review 10 minutes ago: GitHub not asked" "" "$(calls)"

fresh
ACTIVITY=$(ago 10)
check "my push or comment 10 minutes ago: nothing" "" "$(handle_stalled 90 h1abcdef buddy "$(ago 45)")"
check "my push or comment 10 minutes ago: not requested" "activity 90" "$(calls)"
check "my push or comment 10 minutes ago: not recorded" "" "$(cat "$STALLED")"

fresh
ACTIVITY=$(ago 40)
last=$(ago 50)
check "my activity 40 minutes ago, after the review: idle from it" "STALLED #90 buddy buddy" "$(handle_stalled 90 h1abcdef buddy "$last")"
check "my activity 40 minutes ago: logged from it" "stalled #90 at h1abcde: idle since $ACTIVITY, last review by buddy at $last, requested buddy" "$(logged)"

fresh
ACTIVITY=$(ago 90)
check "my activity older than the review: idle from the review" "STALLED #90 buddy buddy" "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"

# --- Failures -----------------------------------------------------------------------
fresh
ACTIVITY_FAILS=1
check "activity unreadable: nothing" "" "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"
check "activity unreadable: not requested, not recorded" "activity 90|" "$(calls)|$(cat "$STALLED")"
check "activity unreadable: logged" "reading my activity on #90 failed; trying again next pass" "$(logged)"

fresh
REQUEST_FAILS=1
last=$(ago 31)
check "request fails: still notified, nobody requested" "STALLED #90 buddy -" "$(handle_stalled 90 h1abcdef buddy "$last")"
check "request fails: logged" "could not request buddy on stalled #90" "$(logged | head -1)"
: >"$TMP/calls"
check "request failed: the next pass waits a whole idle stretch, GitHub not asked" "|" "$(handle_stalled 90 h1abcdef buddy "$last")|$(calls)"

fresh
last=$(ago 31)
handle_stalled 90 h1abcdef buddy "$last" >/dev/null
: >"$TMP/calls"
check "just requested: the next pass does not request again, GitHub not asked" "|" "$(handle_stalled 90 h1abcdef buddy "$last")|$(calls)"
printf '90\t%s\n' "$(ago 31)" >"$STALLED_TRIES"
: >"$TMP/calls"
check "requested 31 minutes ago and still idle: requested again" "activity 90
request 90 buddy" "$(handle_stalled 90 h1abcdef buddy "$last" >/dev/null; calls)"
check "the last request is kept once per PR" "1" "$(grep -c '^90	' "$STALLED_TRIES")"
printf '90\t%s\n91\t%s\n' "$(ago 5)" "$(ago 5)" >"$STALLED_TRIES"
tries_before=$(cat "$STALLED_TRIES")
( awk() { return 2; }; record_stalled_try 92 )
check "a failed read of the tries leaves them as they were, with no temp file" "$tries_before|" \
  "$(cat "$STALLED_TRIES")|$(ls "$STATE_DIR" | grep -c '\.tmp$' | sed 's/^0$//')"
record_stalled_try 92
check "recording a try keeps the other PRs' rows" "90 91 92" "$(cut -f1 "$STALLED_TRIES" | tr '\n' ' ' | sed 's/ $//')"

# --- Re-requests off: the notification only, once per head --------------------------
fresh
STALLED_REREQUEST=false
check "re-requests off: notified" "STALLED #90 buddy -" "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"
check "re-requests off: the same head stays quiet" "" "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"
check "re-requests off: nobody requested" "activity 90" "$(calls)"

# --- Dry run --------------------------------------------------------------------------
fresh
dry_run=1
check "dry run: says what it would do" "DRY_RUN would report #90 as stalled (last review by buddy, request buddy)" \
  "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"
check "dry run: nothing requested or recorded" "activity 90||" "$(calls)|$(cat "$STALLED")|$(cat "$STALLED_TRIES" 2>/dev/null)"
echo "90@h1abcdef" >"$STALLED"
check "dry run, head already reported: says it would request again" "DRY_RUN would request buddy again on stalled #90 (last review by buddy)" \
  "$(handle_stalled 90 h1abcdef buddy "$(ago 31)")"

# --- The activity filter --------------------------------------------------------------
activity_of() {
  gh api user --jq "[\"me-new\",\"me-old\"] as \$me | $1 | $AUTHOR_ACTIVITY_JQ"
}
check "activity: the head commit's date when nothing else" "2026-01-01T10:00:00Z" \
  "$(activity_of '{"commits":[{"committedDate":"2026-01-01T09:00:00Z"},{"committedDate":"2026-01-01T10:00:00Z"}],"comments":[],"reviews":[]}')"
check "activity: my comment, from either login, after the push" "2026-01-01T11:00:00Z" \
  "$(activity_of '{"commits":[{"committedDate":"2026-01-01T10:00:00Z"}],"comments":[{"author":{"login":"me-old"},"createdAt":"2026-01-01T11:00:00Z"}],"reviews":[]}')"
check "activity: my thread reply (a review of mine)" "2026-01-01T12:00:00Z" \
  "$(activity_of '{"commits":[{"committedDate":"2026-01-01T10:00:00Z"}],"comments":[],"reviews":[{"author":{"login":"me-new"},"submittedAt":"2026-01-01T12:00:00Z"}]}')"
check "activity: other people's comments and reviews do not count" "2026-01-01T10:00:00Z" \
  "$(activity_of '{"commits":[{"committedDate":"2026-01-01T10:00:00Z"}],"comments":[{"author":{"login":"buddy"},"createdAt":"2026-01-01T13:00:00Z"}],"reviews":[{"author":{"login":"buddy"},"submittedAt":"2026-01-01T14:00:00Z"},{"author":null,"submittedAt":"2026-01-01T15:00:00Z"}]}')"
check "activity: none at all is empty" "" \
  "$(activity_of '{"commits":[],"comments":[],"reviews":[]}')"

exit "$failed"
