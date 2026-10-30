#!/usr/bin/env bash
# One pass over the open PRs of REPO. The Windows task (windows/poll.ps1) runs it
# every POLL_SECONDS; a pass that finds nothing to review costs no tokens.
#
#   My reviewer-less PR         requests MY_PR_REVIEWER.
#   A watched author's new PR   starts a review run (run_review.sh).
#   A PR that moved past my     starts a re-review run once its head has settled
#   review                      and its checks are green (see classify.jq).
#
# Up to MAX_PARALLEL_REVIEWS runs at a time, counting runs started by other
# passes. A pass waits for the runs it started; passes overlap, so a long review
# does not hold up the next PR. A PR whose run failed MAX_ATTEMPTS times at the
# same head is left alone, with one GAVE_UP line.
#
# Prints one line per event, which windows/poll.ps1 turns into notifications:
#   REQUESTED <reviewer> #<n>       STARTED <key>       GAVE_UP <key>
#   CAPPED #<n> <rounds>            a PR past MAX_CHANGE_ROUNDS got its one comment
#   STALLED #<n> <last reviewer> <login requested again, or ->
#                                   my PR needs an approval and nobody is asked for one
#   and the POSTED / NOT_POSTED / FAILED line of each run (see run_review.sh).
# Prints nothing when there was nothing to do.
#
#   --dry-run   print what it would do; request nothing, start nothing

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

load_config || exit 2

# Run directories are kept for two weeks, for audits of what a review saw and cost.
find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null

if ! open=$(classify_open_prs 2>>"$LOG"); then
  log "listing open PRs failed"
  echo "POLL_FAILED listing open PRs failed, see $LOG"
  exit 1
fi
# When the last pass got as far as the PR list; shows the scheduled task is alive.
date -u +%FT%TZ >"$LAST_POLL"

pids=()
while read -r kind number head reason reviewed; do
  [ -n "$kind" ] || continue
  run_args=("$number")
  key="$number"
  case "$kind" in
    MINE)
      is_handled "own-$number" && continue
      if [ "$dry_run" -eq 1 ]; then
        echo "DRY_RUN would request $MY_PR_REVIEWER on #$number"
      elif request_reviewer "$number" "$MY_PR_REVIEWER" >>"$LOG" 2>&1; then
        echo "own-$number" >>"$HANDLED"
        log "requested $MY_PR_REVIEWER on #$number"
        echo "REQUESTED $MY_PR_REVIEWER #$number"
      else
        log "could not request $MY_PR_REVIEWER on #$number"
      fi
      continue
      ;;
    STALLED)
      # Once per PR head: a new push is the author moving, and may change the picture.
      last_reviewer="$reason"
      last_at="$reviewed"
      grep -qx "$number@$head" "$STALLED" && continue
      age=$(($(date +%s) - $(date -d "$last_at" +%s 2>/dev/null || date +%s)))
      [ "$age" -ge $((${STALLED_AFTER_MINUTES:-30} * 60)) ] || continue
      reviewer=""
      [ "$(json_bool "${STALLED_REREQUEST:-true}")" = "true" ] && reviewer="$MY_PR_REVIEWER"
      if [ "$dry_run" -eq 1 ]; then
        echo "DRY_RUN would report #$number as stalled (last review by $last_reviewer${reviewer:+, request $reviewer})"
        continue
      fi
      requested="-"
      if [ -n "$reviewer" ]; then
        if request_reviewer "$number" "$reviewer" >>"$LOG" 2>&1; then
          requested="$reviewer"
        else
          log "could not request $reviewer on stalled #$number"
        fi
      fi
      echo "$number@$head" >>"$STALLED"
      log "stalled #$number at ${head:0:7}: last review by $last_reviewer at $last_at, requested $requested"
      echo "STALLED #$number $last_reviewer $requested"
      continue
      ;;
    CAPPED)
      # One comment per PR, however many more commits arrive.
      grep -qx "$number" "$CAPPED" && continue
      rounds="$reason"
      if [ "$dry_run" -eq 1 ]; then
        echo "DRY_RUN would comment on #$number: changes requested $rounds times, no more automatic re-reviews"
        continue
      fi
      body="Automated review: I have requested changes on this PR $rounds times, so new commits no longer start another automatic re-review. When it is ready for another look, re-request my review, or let's talk the open points through."
      if gh pr comment "$number" --repo "$REPO" --body "$body" >>"$LOG" 2>&1; then
        echo "$number" >>"$CAPPED"
        log "capped #$number after $rounds change requests"
        echo "CAPPED #$number $rounds"
      else
        log "could not comment on capped #$number"
      fi
      continue
      ;;
    THEIRS) ;;
    REREVIEW)
      key="$number@$head"
      rereview_ready "$key" "$reason" || continue
      run_args=("$number" "$head" "$reason" "$reviewed")
      ;;
    *) continue ;;
  esac

  run_is_live "$key" && continue
  if [ "$(attempts_of "$key")" -ge "$MAX_ATTEMPTS" ]; then
    if ! grep -qx "$key" "$GAVE_UP"; then
      [ "$dry_run" -eq 0 ] && echo "$key" >>"$GAVE_UP"
      log "gave up on $key after $MAX_ATTEMPTS failed runs"
      echo "GAVE_UP $key"
    fi
    continue
  fi
  if [ "$(live_run_count)" -ge "$MAX_PARALLEL_REVIEWS" ]; then
    log "$key waits: $MAX_PARALLEL_REVIEWS reviews are running"
    continue
  fi
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY_RUN would start: run_review.sh ${run_args[*]}"
    continue
  fi

  echo "STARTED $key"
  bash "$SCRIPTS/run_review.sh" "${run_args[@]}" &
  pids+=("$!")
  # Let the run take its lock before the next one is counted.
  sleep 2
done <<<"$open"

for pid in "${pids[@]}"; do
  wait "$pid"
done
exit 0
