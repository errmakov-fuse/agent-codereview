#!/usr/bin/env bash
# Polls the open PRs of REPO every POLL_SECONDS and costs no tokens while quiet.
#
#   My reviewer-less PRs       requests MY_PR_REVIEWER and carries on.
#   A watched author's new PR  requests REVIEW_AS, prints "NEEDS_REVIEW <n> ..."
#                              and exits 0. Run as a background command, that
#                              exit is what wakes the agent.
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

  pending=""
  while read -r kind number; do
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
        pending="$pending $number"
        ;;
    esac
  done <<<"$open"

  if [ -n "$pending" ]; then
    echo "NEEDS_REVIEW$pending"
    exit 0
  fi
  if [ "$once" -eq 1 ]; then
    echo "QUIET"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done
