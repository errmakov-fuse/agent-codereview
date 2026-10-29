#!/usr/bin/env bash
# One pass of the PR update watcher: tells a Claude Code session when a PR it
# owns gets a comment or a review, and once when it is merged or closed. A pass
# with no news spends no tokens and makes one `gh pr list` per watched repository.
#
#   1. The sessions and the PRs in their transcripts (session_prs.js) go into
#      the ledger (watch_lib.sh); a PR's owner is picked by watch_owner.
#   2. Messages that could not go out on an earlier pass are tried again.
#   3. A watched PR whose updatedAt moved has its comments and reviews read;
#      what is new and not from PR_UPDATE_IGNORE_LOGINS (pr_updates.js) is
#      sent to the owner. A PR seen for the first time is enrolled silently.
#   4. A watched PR gone from the open list gets one closing notice, only when
#      its owner is live and the merger or closer is not one of MY_LOGINS, and
#      leaves the watch list. One already closed when first seen gets no notice.
#      So does a PR GitHub says does not exist. A repository GitHub will not
#      resolve (deleted, or hidden from the current gh account) keeps its PRs
#      and is skipped until it resolves again (unreachable.tsv; logged once).
#
# A live session gets the message in its inbox (send_to_session.js). A retired
# background session is woken with `claude --bg --resume <session id> <message>`
# from the folder it ran in, at most PR_UPDATE_MAX_RESUMES_PER_PASS a pass and
# once per session a pass, and only while PR_UPDATE_RESUME_RETIRED is on;
# otherwise its update waits in pending.tsv. A session whose folder is gone is
# never resumed: that counts as a failed delivery. At most
# PR_UPDATE_MAX_PER_PR_PER_DAY messages per PR a day; a message that fails twice
# is dropped. A failed gh pr list skips its repository for the pass; any other
# gh failure skips only that PR.
#
# Prints one line per event, which windows/poll.ps1 turns into notifications:
#   NOTIFIED <owner/repo>#<n> <inbox|resume> <session short id> <summary>
#   NOT_DELIVERED <owner/repo>#<n> <session short id> <why>     tried again next pass
#   WATCH_GAVE_UP <owner/repo>#<n> <session short id>           the message is in poll.log
#   CAPPED_UPDATES <owner/repo>#<n> <count>
#   WATCH_FAILED <why>          the sessions could not be listed; exit 1
# Prints nothing when there was nothing to do, or when PR_UPDATE_ENABLED is off.
#
#   --dry-run    read everything, write and send nothing: the pass runs on a
#                throwaway copy of the ledger and prints DRY_RUN <event> for
#                each event it would print
#   --backfill   a PR seen for the first time counts the comments and reviews
#                already on it as new, instead of enrolling silently

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE_MESSAGE='There is an update on PR %s: %s. Check it out whether any action is needed and proceed if it is.'
MERGED_MESSAGE='PR %s was merged. Nothing is left to do on it; clean up its worktree and branch if you still have them.'
CLOSED_MESSAGE='PR %s was closed without merging. Nothing is left to do on it; clean up its worktree and branch if you still have them.'
MAX_DELIVERY_ATTEMPTS=2

dry_run=0
backfill=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --backfill) backfill=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

load_config || exit 2
[ "$(json_bool "$PR_UPDATE_ENABLED")" = true ] || exit 0

scratch="$(mktemp -d)" || exit 2
if [ "$dry_run" -eq 1 ]; then
  mkdir "$scratch/ledger" && cp -r "$PR_UPDATES_DIR"/. "$scratch/ledger"/ && rm -rf "$scratch/ledger/lock" || exit 2
  PR_UPDATES_DIR="$scratch/ledger"
fi
# shellcheck source=/dev/null
. "$SCRIPTS/watch_lib.sh"
# shellcheck source=/dev/null
. "$SCRIPTS/watch_gh.sh"
trap 'watch_unlock; rm -rf "$scratch"' EXIT
if [ "$dry_run" -eq 0 ] && ! watch_lock; then
  log "watch pass skipped: another pass holds $WATCH_LOCK"
  exit 0
fi

resumes=0     # sessions resumed in this pass
resumed=" "   # their ids, space-separated

now() { date -u +%FT%TZ; }
pr_url() { echo "https://github.com/$1/pull/$2"; }

event() {
  if [ "$dry_run" -eq 1 ]; then echo "DRY_RUN $*"; else echo "$*"; fi
}

is_mine() {
  local mine
  [ -n "$1" ] || return 1
  for mine in $MY_LOGINS; do
    [ "${mine,,}" = "${1,,}" ] && return 0
  done
  return 1
}

watch_failed() {
  log "watch pass failed: $1"
  echo "WATCH_FAILED $1, see $LOG"
}

# --- Sessions ----------------------------------------------------------------

# Refreshes sessions.tsv and watch.tsv. On any failure, or when no session is
# listed, the ledger is left alone: an empty sessions.tsv would drop every watch.
list_sessions() {
  local agents listing note kind repo n session source
  if ! agents=$(claude agents --json --all 2>>"$LOG" </dev/null); then
    watch_failed "claude agents --json --all failed"
    return 1
  fi
  listing=$(printf '%s' "$agents" |
    STATE_DIR="$(winpath "$PR_UPDATES_DIR")" node "$(winpath "$SCRIPTS/session_prs.js")" 2>"$scratch/notes")
  local status=$?
  while IFS= read -r note; do log "$note"; done <"$scratch/notes"
  if [ "$status" -ne 0 ]; then
    watch_failed "session_prs.js failed"
    return 1
  fi
  if ! grep -q $'^SESSION\t' <<<"$listing"; then
    watch_failed "no session listed"
    return 1
  fi
  if ! sessions_save <<<"$listing"; then
    watch_failed "saving the session list failed"
    return 1
  fi
  # scan.tsv has moved past these rows, so a lost one is not offered again.
  while IFS=$'\t' read -r kind repo n session source; do
    [ "$kind" = PR ] || continue
    closed_has "$repo" "$n" && continue
    watch_add "$repo" "$n" "$session" "$source" || log "could not record that session $session watches $repo#$n"
  done <<<"$listing"
  watch_drop_gone
}

# --- Delivery ----------------------------------------------------------------

compose_message() {
  local kind="$1" url
  url=$(pr_url "$2" "$3")
  case "$kind" in
    update) printf "$UPDATE_MESSAGE" "$url" "$4" ;;
    merged) printf "$MERGED_MESSAGE" "$url" ;;
    closed) printf "$CLOSED_MESSAGE" "$url" ;;
  esac
}

can_resume() {
  [ "$(json_bool "$PR_UPDATE_RESUME_RETIRED")" = true ] &&
    [ "$resumes" -lt "$PR_UPDATE_MAX_RESUMES_PER_PASS" ] &&
    [[ "$resumed" != *" $1 "* ]]
}

# How a message of this kind reaches this session now: inbox, resume, wait
# (an update stays pending), nofolder (it would be resumed, but the folder it
# ran in is gone, and waking it anywhere else would let it loose in an
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
  elif can_resume "$owner"; then
    cwd=$(session_field "$owner" cwd) || return 1
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then echo resume; else echo nofolder; fi
  else
    echo wait
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
# nothing here passes through a shell.
send_resume() {
  local owner="$1" message="$2" cwd out
  # `cd ""` stays put, so an unread folder would resume it wherever this runs.
  if ! cwd=$(session_field "$owner" cwd) || [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    echo "session folder could not be read"
    return 1
  fi
  if out=$(cd "$cwd" && claude --bg --resume "$owner" "$message" </dev/null 2>&1); then
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

# --- PRs ---------------------------------------------------------------------

# Reads what is new on a PR since <since> (empty: everything) and sends it.
# Fails when gh or a ledger read does; a bad answer skips this PR for this
# pass. seen moves only once the news is known and its pending row was read.
fetch_updates() {
  local repo="$1" n="$2" updated="$3" since="$4" query comments review_comments reviews result
  local newest summary old
  query="${since:+since=$since&}per_page=$PER_PAGE"
  comments=$(gh api "repos/$repo/issues/$n/comments?$query" 2>>"$LOG" </dev/null) || return 1
  review_comments=$(gh api "repos/$repo/pulls/$n/comments?$query" 2>>"$LOG" </dev/null) || return 1
  reviews=$(gh api "repos/$repo/pulls/$n/reviews?per_page=$PER_PAGE" 2>>"$LOG" </dev/null) || return 1
  if ! result=$(printf '{"comments":%s,"reviewComments":%s,"reviews":%s}' "$comments" "$review_comments" "$reviews" |
    SINCE="$since" IGNORE="$PR_UPDATE_IGNORE_LOGINS" node "$(winpath "$SCRIPTS/pr_updates.js")" 2>>"$LOG"); then
    log "could not read the updates of $repo#$n; trying again next pass"
    return 0
  fi
  # Line 1 the newest kept time or -, line 2 the summary (gone when empty).
  newest="${result%%$'\n'*}"
  summary=""
  [ "$newest" != "$result" ] && summary="${result#*$'\n'}"
  [ "$newest" = - ] && { newest="$since"; [ -n "$newest" ] || newest=$(now); }
  if [ -z "$newest" ] || ! old=$(pending_get "$repo" "$n"); then
    log "reading the ledger for $repo#$n failed; trying again next pass"
    return 1
  fi
  seen_set "$repo" "$n" "$updated" "$newest"
  [ -n "$summary" ] || return 0
  old="${old##*$'\t'}"
  [ -n "$old" ] && summary="$old; then $summary"
  deliver "$repo" "$n" "$summary" update
  return 0
}

# An open PR: enrolled on first sight, read when its updatedAt moved.
check_pr() {
  local repo="$1" n="$2" updated="$3" seen stamp
  if ! seen=$(seen_get "$repo" "$n"); then
    log "reading the seen row of $repo#$n failed; trying again next pass"
    return 1
  fi
  if [ -z "$seen" ]; then
    if [ "$backfill" -eq 1 ]; then
      fetch_updates "$repo" "$n" "$updated" ""
      return
    fi
    stamp=$(now) && [ -n "$stamp" ] || return 1
    seen_set "$repo" "$n" "$updated" "$stamp"
    return 0
  fi
  [[ "$updated" > "${seen%%$'\t'*}" ]] || return 0
  fetch_updates "$repo" "$n" "$updated" "${seen#*$'\t'}"
}

# Takes a PR off the watch list for good, without a notice.
forget_pr() {
  closed_add "$1" "$2"
  watch_drop_pr "$1" "$2"
  pending_drop "$1" "$2"
}

# The closing notice for a merged or closed PR, unless one of MY_LOGINS did it.
notify_closed() {
  local repo="$1" n="$2" state="$3" closer="$4" kind=merged
  if [ "$state" = CLOSED ]; then
    kind=closed
    closer=$(closer_of "$repo" "$n") || return 1
  fi
  is_mine "$closer" && return 0
  deliver "$repo" "$n" "$kind${closer:+ by $closer}" "$kind"
  return 0
}

# A watched PR missing from the open list; <complete> is 1 when that list held
# every open PR. A PR never seen open gets no notice, and with a complete list
# needs no call at all. Fails when gh does: status 2 when GitHub would not
# resolve the repository, 1 otherwise.
settle_closed() {
  local repo="$1" n="$2" complete="$3" seen view status
  if ! seen=$(seen_get "$repo" "$n"); then
    log "reading the seen row of $repo#$n failed; trying again next pass"
    return 1
  fi
  if closed_has "$repo" "$n" || { [ -z "$seen" ] && [ "$complete" -eq 1 ]; }; then
    forget_pr "$repo" "$n"
    return 0
  fi
  view=$(pr_state "$repo" "$n")
  status=$?
  if [ "$status" -eq 3 ]; then
    log "$repo#$n does not exist on GitHub ($(gh_why)); no longer watched"
    forget_pr "$repo" "$n"
    return 0
  fi
  [ "$status" -eq 0 ] || return "$status"
  case "${view%%$'\t'*}" in
    OPEN) return 0 ;; # beyond the first MAX_OPEN_PRS of the open list
    MERGED | CLOSED) ;;
    *)
      log "$repo#$n has state '${view%%$'\t'*}'; looking again next pass"
      return 0
      ;;
  esac
  if [ -n "$seen" ]; then
    notify_closed "$repo" "$n" "${view%%$'\t'*}" "${view#*$'\t'}" || return 1
  fi
  forget_pr "$repo" "$n"
}

watched_in() {
  watch_prs | awk -F'\t' -v repo="$1" '$1 == repo { print $2 }'
}

# The updatedAt of PR <n> in an open list ("<n>\t<updatedAt>" lines), or
# nothing when the PR is not in it. Fails only when the lookup itself does,
# which must not read as "not open": that path can forget the PR.
open_updated_at() {
  awk -F'\t' -v n="$2" '$1 == n { print $2; exit }' <<<"$1"
}

# 1 when an open list holds fewer than MAX_OPEN_PRS PRs, so a PR missing from
# it is not open. An uncountable list counts as full, which only costs a call.
list_is_complete() {
  local count
  count=$(grep -c . <<<"$1")
  case "$count" in
    '' | *[!0-9]*) echo 0 ;;
    *) [ "$count" -lt "$MAX_OPEN_PRS" ] && echo 1 || echo 0 ;;
  esac
}

# A repository GitHub would not resolve keeps its rows and waits; the outage is
# logged when it starts, not on every pass.
repo_unreachable() {
  if unreachable_mark "$1"; then
    log "GitHub cannot resolve the repository $1 (deleted, or hidden from the current gh account): $(gh_why); its PRs are kept and skipped until it can"
  fi
  return 0
}

# One gh pr list for a repository, then each of its watched PRs. A failed list,
# or a repository GitHub stops resolving, skips the repository for this pass;
# a PR that cannot be read otherwise waits for the next pass on its own.
check_repo() {
  local repo="$1" open status complete=0 n updated
  open=$(open_prs_of "$repo")
  status=$?
  if [ "$status" -eq 2 ]; then
    repo_unreachable "$repo"
    return 0
  elif [ "$status" -ne 0 ]; then
    log "listing the open PRs of $repo failed; its PRs wait for the next pass"
    return 0
  fi
  complete=$(list_is_complete "$open") || complete=0
  for n in $(watched_in "$repo"); do
    if ! updated=$(open_updated_at "$open" "$n"); then
      log "reading the open list of $repo failed for #$n; trying again next pass"
      continue
    fi
    if [ -z "$updated" ]; then
      settle_closed "$repo" "$n" "$complete"
    else
      check_pr "$repo" "$n" "$updated"
    fi
    status=$?
    [ "$status" -eq 0 ] && continue
    if [ "$status" -eq 2 ]; then
      repo_unreachable "$repo"
      return 0
    fi
    log "reading $repo#$n failed; trying it again next pass"
  done
  unreachable_clear "$repo" && log "the repository $repo is reachable again"
  return 0
}

# Tests only: a file sourced after every function above is defined, so a test
# can replace one (tests/watch_pass.sh makes a lookup fail this way).
if [ -n "$WATCH_PASS_TEST_HOOK" ]; then
  # shellcheck source=/dev/null
  . "$WATCH_PASS_TEST_HOOK"
fi

list_sessions || exit 1
retry_pending
for repo in $(watch_prs | awk -F'\t' '!seen[$1]++ { print $1 }'); do
  check_repo "$repo"
done
exit 0
