#!/usr/bin/env bash
# Polls the open PRs of REPO every POLL_SECONDS and costs no tokens while quiet.
#
# Which PRs count (drafts, skip keywords, re-review reasons) is decided in
# classify.jq.
#
#   My reviewer-less PRs       requests MY_PR_REVIEWER and carries on.
#   A watched author's new PR  requests REVIEW_AS and reports it for review.
#   A watched author's PR that moved past my review (changes were requested, my
#   approval was dismissed, or I was re-requested) reports it for re-review once
#   its head has settled.
#
# When anything needs a review it prints one or both of these lines and exits 0.
# Run as a background command, that exit is what wakes the agent.
#
#   NEEDS_REVIEW <n> ...
#   NEEDS_REREVIEW <n>@<head sha> ...
#
# Options:
#   --once     run one poll and exit (prints "QUIET" when nothing needs review)
#   --dry-run  print the reviewer requests instead of making them
#
# Exits 1 with "WATCHER_FAILED ..." after MAX_FAILURES failed polls in a row.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAX_FAILURES=6
once=0
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --once) once=1 ;;
    --dry-run) dry_run=1 ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

load_config || exit 2

# A watcher that has exited, including after handing over a PR, must not look
# alive: the session it was meant to wake may never get the exit (a background
# command stopped for low memory carries on detached), and the watchdog judges
# by the heartbeat alone. So on any exit the heartbeat is reset, and the next
# watchdog run reports DEAD and takes over the hand-off. Not with --once, which
# is a manual check that may run beside a live watcher.
if [ "$once" -eq 0 ]; then
  trap 'echo 0 >"$HEARTBEAT"' EXIT
fi

ask_for_review() {
  local number="$1" reviewer="$2"
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY_RUN would request $reviewer on #$number"
    return 0
  fi
  if request_reviewer "$number" "$reviewer" >>"$LOG" 2>&1; then
    echo "$(date -u +%FT%TZ) requested $reviewer on #$number" >>"$LOG"
    return 0
  fi
  echo "$(date -u +%FT%TZ) could not request $reviewer on #$number" >>"$LOG"
  return 1
}

failures=0
while true; do
  date +%s >"$HEARTBEAT"

  if ! open=$(classify_open_prs 2>>"$LOG"); then
    failures=$((failures + 1))
    if [ "$failures" -ge "$MAX_FAILURES" ] || [ "$once" -eq 1 ]; then
      echo "WATCHER_FAILED listing PRs failed $failures time(s) in a row, see $LOG"
      exit 1
    fi
    sleep "$POLL_SECONDS"
    continue
  fi
  failures=0

  first_reviews=""
  rereviews=""
  while read -r kind number head reason _; do
    case "$kind" in
      MINE)
        is_handled "own-$number" && continue
        if ask_for_review "$number" "$MY_PR_REVIEWER" && [ "$dry_run" -eq 0 ]; then
          echo "own-$number" >>"$HANDLED"
        fi
        ;;
      THEIRS)
        is_handled "$number" && continue
        # A failed request must not hide the PR: the agent retries it.
        ask_for_review "$number" "$REVIEW_AS"
        first_reviews="$first_reviews $number"
        ;;
      REREVIEW)
        is_handled "$number@$head" && continue
        rereview_ready "$number@$head" "$reason" || continue
        rereviews="$rereviews $number@$head"
        ;;
    esac
  done <<<"$open"

  if [ -n "$first_reviews$rereviews" ]; then
    [ -n "$first_reviews" ] && echo "NEEDS_REVIEW$first_reviews"
    [ -n "$rereviews" ] && echo "NEEDS_REREVIEW$rereviews"
    exit 0
  fi
  if [ "$once" -eq 1 ]; then
    echo "QUIET"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done
