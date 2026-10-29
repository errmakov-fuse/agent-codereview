#!/usr/bin/env bash
# The PR update watcher's delivery: how a message reaches a session, and what
# the ledger records when it does or does not. Sourced by watch_pr_updates.sh
# after lib.sh and watch_lib.sh; uses its event, pr_url, $dry_run and resume
# counters.

UPDATE_MESSAGE='There is an update on PR %s: %s. Check it out whether any action is needed and proceed if it is.'
MERGED_MESSAGE='PR %s was merged. Nothing is left to do on it; clean up its worktree and branch if you still have them.'
CLOSED_MESSAGE='PR %s was closed without merging. Nothing is left to do on it; clean up its worktree and branch if you still have them.'
MAX_DELIVERY_ATTEMPTS=2
# Claude Code's registry of running sessions, one <pid>.json each.
CLAUDE_REGISTRY="${CLAUDE_HOME:-$HOME/.claude}/sessions"

compose_message() {
  local kind="$1" url
  url=$(pr_url "$2" "$3")
  case "$kind" in
    update) printf "$UPDATE_MESSAGE" "$url" "$4" ;;
    merged) printf "$MERGED_MESSAGE" "$url" ;;
    closed) printf "$CLOSED_MESSAGE" "$url" ;;
  esac
}

# A resume slot for this session in this pass: under the per-pass cap, and not
# resumed already (a second --bg --resume on a session now running would start
# a copy of it).
can_resume() {
  [ "$resumes" -lt "$PR_UPDATE_MAX_RESUMES_PER_PASS" ] && [[ "$resumed" != *" $1 "* ]]
}

# True when Claude Code's registry has an entry for this session, so it is
# running now. The listing is from the start of the pass; a session reopened
# since then would be copied by a resume, not woken.
session_registered() {
  grep -qsF "\"sessionId\":\"$1\"" "$CLAUDE_REGISTRY"/*.json
}

# How a message of this kind reaches this session now: inbox, resume, wait
# (an update stays pending: no resume slot this pass), off (the same, because
# PR_UPDATE_RESUME_RETIRED is off), alive (the same, because the session has
# come alive since the listing), nofolder (it would be resumed, but the folder
# it ran in is gone, and waking it anywhere else would let it loose in an
# unrelated repository) or skip (a closing notice for a retired session).
# Fails when the session cannot be read: a live session taken for a retired
# one would be resumed, which starts a copy of it.
route_for() {
  local owner="$1" kind="$2" status cwd
  status=$(session_field "$owner" status) || return 1
  case "$status" in
    live)
      echo inbox
      return 0
      ;;
    retired) ;;
    *) return 1 ;;
  esac
  if [ "$kind" != update ]; then
    echo skip
  elif [ "$(json_bool "$PR_UPDATE_RESUME_RETIRED")" != true ]; then
    echo off
  elif ! can_resume "$owner"; then
    echo wait
  elif session_registered "$owner"; then
    echo alive
  else
    cwd=$(session_field "$owner" cwd) || return 1
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then echo resume; else echo nofolder; fi
  fi
}

# Writes the message into a live session's inbox; on failure prints why.
send_inbox() {
  local owner="$1" message="$2" pid why
  pid=$(session_field "$owner" pid)
  why=$(printf '%s' "$message" | node "$(winpath "$SCRIPTS/send_to_session.js")" "$pid" "$owner" 2>&1 >/dev/null) &&
    return 0
  printf '%s\n' "${why:-send_to_session.js failed}" | tail -n 1
  return 1
}

# Wakes a retired session with the message as its next turn, from the folder it
# ran in (route_for has checked it exists). The message is one argument;
# nothing here passes through a shell. A resume whose output speaks of a copy
# or a fork reached a new session, not this one: that is a failure, and the
# line saying so is the reason.
send_resume() {
  local owner="$1" message="$2" cwd out copy
  # `cd ""` stays put, so an unread folder would resume it wherever this runs.
  if ! cwd=$(session_field "$owner" cwd) || [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    echo "session folder could not be read"
    return 1
  fi
  if out=$(cd "$cwd" && claude --bg --resume "$owner" "$message" </dev/null 2>&1); then
    copy=$(grep -iE 'copy|fork' <<<"$out" | head -n 1)
    if [ -n "$copy" ]; then
      log "resuming session $owner started a copy of it, not the session itself: ${out//$'\n'/ | }"
      printf '%s\n' "$copy"
      return 1
    fi
    log "resumed session $owner: ${out//$'\n'/ | }"
    return 0
  fi
  log "resuming session $owner failed: ${out//$'\n'/ | }"
  printf '%s\n' "${out:-claude --bg --resume failed}" | tail -n 1
  return 1
}

transmit() {
  [ "$dry_run" -eq 1 ] && return 0
  case "$1" in
    inbox) send_inbox "$2" "$3" ;;
    resume) send_resume "$2" "$3" ;;
  esac
}

# The attempts so far of a PR's pending update (empty when there is none).
pending_attempts() {
  local row
  row=$(pending_get "$1" "$2") || return 1
  row="${row#*$'\t'}"
  printf '%s\n' "${row%%$'\t'*}"
}

# Keeps an update in pending.tsv for a later pass, its attempts unchanged. An
# unreadable count is taken as 0: at worst one more try before giving up.
defer_update() {
  local repo="$1" n="$2" owner="$3" summary="$4" attempts
  attempts=$(pending_attempts "$repo" "$n") || attempts=""
  pending_set "$repo" "$n" "$owner" "${attempts:-0}" "$summary"
}

# A failed update: one more attempt in pending.tsv, or given up after the last.
count_failure() {
  local repo="$1" n="$2" owner="$3" short="$4" summary="$5" why="$6" attempts
  attempts=$(pending_attempts "$repo" "$n") || attempts=""
  attempts=$((${attempts:-0} + 1))
  if [ "$attempts" -ge "$MAX_DELIVERY_ATTEMPTS" ]; then
    pending_drop "$repo" "$n"
    log "gave up on $repo#$n for session $owner after $attempts attempts: $summary"
    event "WATCH_GAVE_UP $repo#$n $short"
    return 0
  fi
  pending_set "$repo" "$n" "$owner" "$attempts" "$summary"
  event "NOT_DELIVERED $repo#$n $short $why"
}

# An update for a retired session while PR_UPDATE_RESUME_RETIRED is off: it
# waits in pending.tsv until the session is live again, and the owner is told
# once (WAITING) when it is new news. The same summary tried again on a later
# pass says nothing more.
hold_while_off() {
  local repo="$1" n="$2" owner="$3" summary="$4" old
  old=$(pending_get "$repo" "$n") || old=""
  defer_update "$repo" "$n" "$owner" "$summary"
  log "$repo#$n waits: session $owner is retired and PR_UPDATE_RESUME_RETIRED is off"
  [ -n "$old" ] && [ "${old##*$'\t'}" = "$(watch_field "$summary")" ] && return 0
  event "WAITING $repo#$n $(session_field "$owner" short) $summary"
}

# Sends one message by inbox or resume and records the outcome.
send_message() {
  local repo="$1" n="$2" owner="$3" route="$4" summary="$5" kind="$6" short message why
  short=$(session_field "$owner" short)
  if ! message=$(compose_message "$kind" "$repo" "$n" "$summary") || [ -z "$message" ]; then
    log "composing the message for $repo#$n failed: $summary"
    [ "$kind" = update ] && defer_update "$repo" "$n" "$owner" "$summary"
    return 0
  fi
  if [ "$route" = resume ]; then
    resumes=$((resumes + 1))
    resumed="$resumed$owner "
  fi
  if why=$(transmit "$route" "$owner" "$message"); then
    sent_record "$repo" "$n" "$owner" "$route" ok "$summary"
    pending_drop "$repo" "$n"
    event "NOTIFIED $repo#$n $route $short $summary"
    return 0
  fi
  sent_record "$repo" "$n" "$owner" "$route" failed "$summary"
  log "sending $repo#$n to session $owner by $route failed: $why"
  if [ "$kind" = update ]; then
    count_failure "$repo" "$n" "$owner" "$short" "$summary" "$why"
  fi
}

# True when an update to a PR is over the daily cap; drops it and says so. An
# unreadable count lets the update through: at worst one over the cap.
over_cap() {
  local repo="$1" n="$2" summary="$3" count
  if ! count=$(sent_last_day "$repo" "$n") || [ -z "$count" ]; then
    log "counting the messages of $repo#$n failed; not capping this one"
    return 1
  fi
  [ "$count" -ge "$PR_UPDATE_MAX_PER_PR_PER_DAY" ] || return 1
  log "$repo#$n had $count messages in the last day; not forwarded: $summary"
  pending_drop "$repo" "$n"
  event "CAPPED_UPDATES $repo#$n $count"
}

# deliver <repo> <n> <summary> <update|merged|closed>. An update that cannot be
# routed now is kept in pending.tsv, never dropped.
deliver() {
  local repo="$1" n="$2" summary="$3" kind="$4" owner route
  [ "$kind" = update ] && over_cap "$repo" "$n" "$summary" && return 0
  if ! owner=$(watch_owner "$repo" "$n"); then
    route=unknown owner=-
  elif [ -z "$owner" ]; then
    log "$repo#$n has no session watching it any more; dropped: $summary"
    pending_drop "$repo" "$n"
    return 0
  elif ! route=$(route_for "$owner" "$kind"); then
    route=unknown
  fi
  case "$route" in
    inbox | resume) send_message "$repo" "$n" "$owner" "$route" "$summary" "$kind" ;;
    wait)
      defer_update "$repo" "$n" "$owner" "$summary"
      log "$repo#$n waits: session $owner is retired and cannot be resumed in this pass"
      ;;
    off) hold_while_off "$repo" "$n" "$owner" "$summary" ;;
    alive)
      defer_update "$repo" "$n" "$owner" "$summary"
      log "session $owner came alive since the listing; waiting ($repo#$n)"
      ;;
    nofolder)
      log "$repo#$n: not resuming session $owner, its folder is gone"
      count_failure "$repo" "$n" "$owner" "$(session_field "$owner" short)" "$summary" "session folder is gone"
      ;;
    skip) log "$repo#$n $summary; session $owner is retired, so it gets no notice" ;;
    *)
      log "could not read how to reach session $owner for $repo#$n: $kind $summary; updates wait for the next pass"
      [ "$kind" = update ] && defer_update "$repo" "$n" "$owner" "$summary"
      ;;
  esac
  return 0
}

# Pending rows are read before any is rewritten.
retry_pending() {
  local rows repo n session attempts summary
  [ -f "$WATCH_PENDING" ] || return 0
  rows=$(cat "$WATCH_PENDING")
  while IFS=$'\t' read -r repo n session attempts summary; do
    [ -n "$repo" ] || continue
    deliver "$repo" "$n" "$summary" update
  done <<<"$rows"
}
