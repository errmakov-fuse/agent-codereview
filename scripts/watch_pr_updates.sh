#!/usr/bin/env bash
# One pass of the PR update watcher: tells a Claude Code session when a PR it
# owns gets a comment or a review, and once when it is merged or closed. A pass
# with no news spends no tokens and makes one `gh pr list` per watched repository.
#
#   1. The sessions and the PRs in their transcripts (session_prs.js) go into
#      the ledger (watch_lib.sh); a PR's owner is picked by watch_owner. The
#      reviewer's own runs (named REVIEW_SESSION_NAME) are never watched.
#   2. Messages that could not go out on an earlier pass are tried again.
#   3. A watched PR whose updatedAt moved has its comments and reviews read;
#      what is new and not from PR_UPDATE_IGNORE_LOGINS (pr_updates.js) is
#      sent to the owner. A PR seen for the first time is enrolled silently.
#      One of MY_LOGINS' PRs that the open list says is CONFLICTING with its
#      base is news once, first sight included, in the same message as its
#      comments (check_open); it is news again only after it was mergeable.
#      A merge conflict does not move updatedAt, so this costs no extra call.
#   4. A watched PR gone from the open list gets one closing notice, only when
#      its owner is live and the merger or closer is not one of MY_LOGINS, and
#      leaves the watch list. One already closed when first seen gets no notice.
#      So does a PR GitHub says does not exist. A repository GitHub will not
#      resolve (deleted, or hidden from the current gh account) keeps its PRs
#      and is skipped until it resolves again (unreachable.tsv; logged once).
#
# A live session gets the message in its inbox (send_to_session.js). A retired
# background session is woken with `claude --bg --resume <session id> <message>`
# from the folder it ran in (watch_deliver.sh), at most
# PR_UPDATE_MAX_RESUMES_PER_PASS a pass and once per session a pass, and only
# while PR_UPDATE_RESUME_RETIRED is on; otherwise its update waits in
# pending.tsv, announced by WAITING when the switch is off. A session that has
# come alive since the listing is not resumed either: it waits for the inbox. A
# session whose folder is gone is never resumed: that counts as a failed
# delivery. A resume that says it started a copy is given up at once
# (WATCH_GAVE_UP), since another try could start another copy. At most
# PR_UPDATE_MAX_PER_PR_PER_DAY messages per PR a day; a message that fails twice
# is dropped. A failed gh pr list skips its repository for the pass; any other
# gh failure skips only that PR.
#
# Prints one line per event, which windows/poll.ps1 turns into notifications:
#   NOTIFIED <owner/repo>#<n> <inbox|resume> <session short id> <summary>
#   NOT_DELIVERED <owner/repo>#<n> <session short id> <why>     tried again next pass
#   WATCH_GAVE_UP <owner/repo>#<n> <session short id>           the message is in poll.log
#   CAPPED_UPDATES <owner/repo>#<n> <count>
#   WAITING <owner/repo>#<n> <session short id> <summary>      the session is retired and
#                               PR_UPDATE_RESUME_RETIRED is off; said once per new update
#   WATCH_FAILED <why>          the sessions could not be listed; exit 1
# Prints nothing when there was nothing to do, or when PR_UPDATE_ENABLED is off.
#
#   --dry-run    read everything, write and send nothing: the pass runs on a
#                throwaway copy of the ledger and prints DRY_RUN <event> for
#                each event it would print
#   --backfill   a PR seen for the first time counts the comments and reviews
#                already on it as new, instead of enrolling silently

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
# shellcheck source=/dev/null
. "$SCRIPTS/watch_deliver.sh"
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

# The listing without the reviewer's own runs, SESSION and PR lines alike (a
# session's PR lines follow its SESSION line). The spec says they are never
# watched: their transcripts name the PRs they review, and a run must not be
# told about the review it posted. Whether `claude agents --json --all` lists
# `claude -p` runs at all was not verified, so they are told apart by the name
# claude_lean.sh gives them.
without_review_runs() {
  awk -F'\t' -v name="$REVIEW_SESSION_NAME" '
    $1 == "SESSION" && $8 == name { review[$3] = 1; next }
    $1 == "PR" && ($4 in review) { next }
    { print }'
}

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
  listing=$(without_review_runs <<<"$listing")
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

# --- PRs ---------------------------------------------------------------------

# Reads what is new on a PR since <since> (empty: everything) and sends it.
# Fails when gh or a ledger read does; a bad answer skips this PR for this
# pass. seen moves only once the news is known and its pending row was read.
fetch_updates() {
  local repo="$1" n="$2" updated="$3" since="$4" note="$5" query comments review_comments reviews result
  local newest summary old
  query="${since:+since=$since&}per_page=$PER_PAGE"
  comments=$(gh api "repos/$repo/issues/$n/comments?$query" 2>>"$LOG" </dev/null) || return 1
  review_comments=$(gh api "repos/$repo/pulls/$n/comments?$query" 2>>"$LOG" </dev/null) || return 1
  reviews=$(gh api "repos/$repo/pulls/$n/reviews?per_page=$PER_PAGE" 2>>"$LOG" </dev/null) || return 1
  if ! result=$(printf '{"comments":%s,"reviewComments":%s,"reviews":%s}' "$comments" "$review_comments" "$reviews" |
    SINCE="$since" IGNORE="$PR_UPDATE_IGNORE_LOGINS" node "$(winpath "$SCRIPTS/pr_updates.js")" 2>>"$LOG"); then
    log "could not read the updates of $repo#$n; trying again next pass"
    send_news "$repo" "$n" "$note"
    return
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
  queue_update "$repo" "$n" "$old" "$(join_news "$summary" "$note")"
  return 0
}

# "<a>; <b>", or whichever of the two is not empty.
join_news() {
  if [ -n "$1" ] && [ -n "$2" ]; then echo "$1; $2"; else echo "$1$2"; fi
}

# queue_update <repo> <n> <pending row> <summary>: delivers <summary> as an
# update, after the one still pending for the PR. The row is pending_get's,
# read before the ledger moved.
queue_update() {
  local repo="$1" n="$2" old="${3##*$'\t'}" summary="$4"
  [ -n "$summary" ] || return 0
  [ -n "$old" ] && summary="$old; then $summary"
  deliver "$repo" "$n" "$summary" update
}

# Delivers <summary>, if any, as an update. Fails when the pending row cannot
# be read, so the caller tries again next pass.
send_news() {
  local old
  [ -n "$3" ] || return 0
  if ! old=$(pending_get "$1" "$2"); then
    log "reading the ledger for $1#$2 failed; trying again next pass"
    return 1
  fi
  queue_update "$1" "$2" "$old" "$3"
}

# An open PR: enrolled on first sight, read when its updatedAt moved. <note>,
# news the open list itself gave (a conflict), goes out in the same message as
# its comments and reviews, or alone. Status 0 means the note was handed on.
check_pr() {
  local repo="$1" n="$2" updated="$3" note="$4" seen stamp
  if ! seen=$(seen_get "$repo" "$n"); then
    log "reading the seen row of $repo#$n failed; trying again next pass"
    return 1
  fi
  if [ -z "$seen" ]; then
    if [ "$backfill" -eq 1 ]; then
      fetch_updates "$repo" "$n" "$updated" "" "$note"
      return
    fi
    stamp=$(now) && [ -n "$stamp" ] || return 1
    seen_set "$repo" "$n" "$updated" "$stamp"
    send_news "$repo" "$n" "$note"
    return
  fi
  if [[ "$updated" > "${seen%%$'\t'*}" ]]; then
    fetch_updates "$repo" "$n" "$updated" "${seen#*$'\t'}" "$note"
  else
    send_news "$repo" "$n" "$note"
  fi
}

# An open PR from the open list. One of MY_LOGINS' PRs that has just gone into
# conflict with its base is news once: conflicts.tsv remembers it was told
# until GitHub calls the PR mergeable again. UNKNOWN (GitHub has not worked it
# out yet) changes nothing. A teammate's PR is never news this way: the session
# that mentioned it must not rebase someone else's branch.
check_open() {
  local repo="$1" n="$2" updated="$3" mergeable="$4" author="$5" base="$6" note=""
  [ "$base" = - ] && base="its base branch"
  case "$mergeable" in
    MERGEABLE) conflict_has "$repo" "$n" && conflict_drop "$repo" "$n" ;;
    CONFLICTING)
      if is_mine "$author" && ! conflict_has "$repo" "$n"; then
        # shellcheck disable=SC2059
        note=$(printf "$CONFLICT_SUMMARY" "$base" "$base")
      fi
      ;;
  esac
  check_pr "$repo" "$n" "$updated" "$note" || return
  [ -z "$note" ] || conflict_add "$repo" "$n"
}

# Takes a PR off the watch list for good, without a notice.
forget_pr() {
  closed_add "$1" "$2"
  watch_drop_pr "$1" "$2"
  pending_drop "$1" "$2"
  conflict_drop "$1" "$2"
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

# The row of PR <n> in an open list (open_prs_of), or nothing when the PR is
# not in it. Fails only when the lookup itself does, which must not read as
# "not open": that path can forget the PR.
open_row() {
  awk -F'\t' -v n="$2" '$1 == n { print; exit }' <<<"$1"
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
  local repo="$1" open status complete=0 n row updated mergeable author base
  open=$(open_prs_of "$repo")
  status=$?
  case "$status" in
    0) complete=$(list_is_complete "$open") || complete=0 ;;
    4) ;; # PRs were left out of it, so one missing from it is looked up
    2)
      repo_unreachable "$repo"
      return 0
      ;;
    *)
      log "listing the open PRs of $repo failed; its PRs wait for the next pass"
      return 0
      ;;
  esac
  for n in $(watched_in "$repo"); do
    if ! row=$(open_row "$open" "$n"); then
      log "reading the open list of $repo failed for #$n; trying again next pass"
      continue
    fi
    if [ -z "$row" ]; then
      settle_closed "$repo" "$n" "$complete"
    else
      IFS=$'\t' read -r _ updated mergeable author base <<<"$row"
      check_open "$repo" "$n" "$updated" "$mergeable" "$author" "$base"
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
log_no_updated_at
exit 0
