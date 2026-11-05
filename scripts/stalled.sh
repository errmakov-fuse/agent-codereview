#!/usr/bin/env bash
# My stalled PR (STALLED in classify.jq): it still needs an approval, its reviews
# are only comments, and nobody is requested. Sourced by poll.sh after lib.sh;
# uses its $dry_run.
#
# Once the PR has been idle for STALLED_AFTER_MINUTES, MY_PR_REVIEWER is requested
# again, and again after every later idle stretch, until someone approves. Any
# review, and any push or comment of mine, restarts the clock. The notification
# comes once per PR head, so a PR stuck all day does not keep popping up.
# STALLED_REREQUEST=false keeps only that notification.

# My latest activity on a PR, from `gh pr view --json commits,comments,reviews`
# with $me bound: the head commit's date, or my latest comment or review (a reply
# in a review thread is a review), whichever is newest. Empty when there is none.
# GitHub gives no push time, so a commit pushed long after it was made does not
# restart the clock; at worst that PR is requested again right after the push.
AUTHOR_ACTIVITY_JQ='[((.commits // []) | last | .committedDate?),
   ((.comments // [])[] | select((.author.login? // "") as $login | $me | any(. == $login)) | .createdAt),
   ((.reviews // [])[] | select((.author.login? // "") as $login | $me | any(. == $login)) | .submittedAt)]
  | map(select(. != null and . != "")) | max // ""'

author_activity_at() {
  local me
  me=$(json_array "$MY_LOGINS") || return 1
  gh pr view "$1" --repo "$REPO" --json commits,comments,reviews --jq "$me as \$me | $AUTHOR_ACTIVITY_JQ"
}

# True when this ISO time is at least STALLED_AFTER_MINUTES ago. An unreadable
# time counts as now.
idle_since() {
  local at
  at=$(date -d "$1" +%s 2>/dev/null) || at=$(date +%s)
  [ $(($(date +%s) - at)) -ge $((${STALLED_AFTER_MINUTES:-30} * 60)) ]
}

# When MY_PR_REVIEWER was last requested on this stalled PR, as ISO; empty if never.
last_stalled_try() {
  awk -F'\t' -v n="$1" '$1 == n { at = $2 } END { print at }' "$STALLED_TRIES" 2>/dev/null
}

# Keeps one row per PR: <n> TAB <ISO time of the last request, made or failed>.
record_stalled_try() {
  local rows
  rows=$(awk -F'\t' -v n="$1" '$1 != n' "$STALLED_TRIES" 2>/dev/null)
  { [ -z "$rows" ] || printf '%s\n' "$rows"; printf '%s\t%s\n' "$1" "$(date -u +%FT%TZ)"; } >"$STALLED_TRIES"
}

# handle_stalled <n> <head> <last reviewer> <last review at>. Prints the STALLED
# line for poll.ps1 when this head has not been reported yet.
handle_stalled() {
  local number="$1" head="$2" last_reviewer="$3" last_at="$4"
  local reviewer="" reported=0 since activity requested="-"
  [ "$(json_bool "${STALLED_REREQUEST:-true}")" = "true" ] && reviewer="$MY_PR_REVIEWER"
  grep -qx "$number@$head" "$STALLED" && reported=1
  [ -n "$reviewer" ] || [ "$reported" -eq 0 ] || return 0
  # The review time and the last request are at hand; GitHub is asked about my
  # activity only after both. A request that failed waits a whole idle stretch too.
  since="$last_at"
  try=$(last_stalled_try "$number")
  [[ "$try" > "$since" ]] && since="$try"
  idle_since "$since" || return 0
  if ! activity=$(author_activity_at "$number"); then
    log "reading my activity on #$number failed; trying again next pass"
    return 0
  fi
  [[ "$activity" > "$since" ]] && since="$activity"
  idle_since "$since" || return 0
  if [ "$dry_run" -eq 1 ]; then
    if [ "$reported" -eq 1 ]; then
      echo "DRY_RUN would request $reviewer again on stalled #$number (last review by $last_reviewer)"
    else
      echo "DRY_RUN would report #$number as stalled (last review by $last_reviewer${reviewer:+, request $reviewer})"
    fi
    return 0
  fi
  if [ -n "$reviewer" ]; then
    if request_reviewer "$number" "$reviewer" >>"$LOG" 2>&1; then
      requested="$reviewer"
    else
      log "could not request $reviewer on stalled #$number"
    fi
    record_stalled_try "$number"
  fi
  log "stalled #$number at ${head:0:7}: idle since $since, last review by $last_reviewer at $last_at, requested $requested"
  [ "$reported" -eq 0 ] || return 0
  echo "$number@$head" >>"$STALLED"
  echo "STALLED #$number $last_reviewer $requested"
}
