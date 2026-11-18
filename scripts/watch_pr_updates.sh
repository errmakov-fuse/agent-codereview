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
#      sent to the owner. A PR seen for the first time is enrolled silently,
#      unless a session created it: then all that is already on it is news,
#      since a review bot can answer before the first pass sees the PR. The
#      first pass without a seen.tsv enrols every PR silently (seen_seeding).
#      One of MY_LOGINS' PRs that the open list says is CONFLICTING with its
#      base is news once, first sight included, in the same message as its
#      comments (check_open); it is news again only after it was mergeable.
#      Each check of one of MY_LOGINS' PRs that fails is news once, as soon as
#      it fails, even while other checks still run (checks.tsv, by job link; a
#      re-run is a new job). The same open list gives its checks. The first
#      pass without a checks.tsv records the failures silently (checks_seeding).
#      Neither a merge conflict nor a check moves updatedAt, so this costs no
#      extra call.
#      Once one of MY_LOGINS' PRs is green, GitHub's mergeStateStatus from the
#      same list says what is left (merge_step): CLEAN prints READY_TO_MERGE
#      once per head, for me to merge; BLOCKED on unresolved review threads, or
#      BEHIND its base, tells its session what blocks it. Threads cost one
#      GraphQL call, made only when such a PR is BLOCKED and moved, or has news
#      (its news then names them too).
#   4. A watched PR gone from the open list gets one closing notice and leaves
#      the watch list. A merge notice goes to a live owner, or resumes a retired
#      one when a resume can go in this pass. A close notice goes to a live
#      owner only, and not when one of MY_LOGINS closed it. One already closed when first seen gets no notice.
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
#   READY_TO_MERGE <owner/repo>#<n> <head short sha>   one of my PRs is green and
#                               GitHub lets it merge; said once per head
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
MAX_NAMED_CHECKS=3   # failed checks named in one message; the rest are counted
# 1 on the first pass with failed-check notices (no checks.tsv yet): the checks
# already red on my PRs are recorded without a message, so turning this on does
# not wake every session whose PR has been red for days. The pass then writes
# the file, even empty, and from the next pass on a failure is news.
checks_seeding=0
[ -e "$WATCH_CHECKS" ] || checks_seeding=1
# 1 on the very first pass (no seen.tsv yet): every PR is enrolled silently, so
# turning the watcher on does not replay the history of every PR the sessions
# ever created. The pass then writes the file, even empty.
seen_seeding=0
[ -e "$WATCH_SEEN" ] || seen_seeding=1

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
  summary=$(with_open_threads "$repo" "$n" "$summary")
  queue_update "$repo" "$n" "$old" "$(join_news "$summary" "$note")"
  return 0
}

# News on one of MY_LOGINS' PRs names its unresolved review threads too, so the
# session answers each inside its thread; a thread answered only in a PR comment
# stays open and keeps the PR from merging. Unchanged for other PRs, for no
# news, when this pass's notice names the threads already, or when they cannot
# be read (logged; the news still goes).
with_open_threads() {
  local repo="$1" n="$2" summary="$3" phrase
  if [ "$pr_is_mine" != 1 ] || [ -z "$summary" ] || { [ "$merge_next" = threads ] && [ -n "$merge_news" ]; }; then
    printf '%s' "$summary"
    return 0
  fi
  if [ -z "$pr_threads" ] && ! pr_threads=$(unresolved_threads_of "$repo" "$n"); then
    log "reading the review threads of $repo#$n failed; its news goes without them"
    pr_threads=""
  fi
  phrase=$(threads_phrase "$pr_threads")
  printf '%s' "$summary${phrase:+; $phrase}"
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
# A PR a session created is read in full on first sight: a review bot can
# answer between `gh pr create` and the next pass, and a silent enrolment
# would count that review as handled. Other PRs, and every PR on the very
# first pass, are enrolled silently.
check_pr() {
  local repo="$1" n="$2" updated="$3" note="$4" seen stamp created
  if ! seen=$(seen_get "$repo" "$n"); then
    log "reading the seen row of $repo#$n failed; trying again next pass"
    return 1
  fi
  if [ -z "$seen" ]; then
    if ! created=$(watch_created "$repo" "$n"); then
      log "reading the watch rows of $repo#$n failed; trying again next pass"
      return 1
    fi
    if [ "$backfill" -eq 1 ] || { [ -n "$created" ] && [ "$seen_seeding" -eq 0 ]; }; then
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

# "a", "a and b", "a, b and c".
join_and() {
  local out="" i
  for ((i = 1; i <= $#; i++)); do
    if [ "$i" -eq 1 ]; then out="${!i}"
    elif [ "$i" -eq $# ]; then out="$out and ${!i}"
    else out="$out, ${!i}"; fi
  done
  printf '%s' "$out"
}

# checks_note <repo> <n> <head sha> <running> <failed>, the last three as
# open_prs_of gives them. Sets checks_now to the keys failing now, checks_had
# to those checks.tsv has, and checks_news to the news of the failed checks the
# session was not told about yet, or nothing. A key leaves checks.tsv when its
# check stops failing, so a re-run that fails again is a new job and news again.
# Fails when checks.tsv cannot be read.
checks_note() {
  local repo="$1" n="$2" head="$3" running="$4" failed="$5" entry key name url commit
  local entries=() names=() urls=() named=() i
  checks_now=()
  checks_news=""
  checks_had=$(checks_known "$repo" "$n") || return 1
  [ "$failed" = - ] || IFS=$'\x1e' read -ra entries <<<"$failed"
  for entry in "${entries[@]}"; do
    IFS=$'\x1f' read -r key name url <<<"$entry"
    checks_now+=("$key")
    grep -qxF -- "$key" <<<"$checks_had" && continue
    names+=("$name")
    urls+=("$url")
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  commit="${head:0:7}"
  [ "$head" = - ] && commit="its head commit"
  if [ "${#names[@]}" -eq 1 ]; then
    checks_news="check ${names[0]} failed on $commit${urls[0]:+ (${urls[0]})}"
  else
    # A failed matrix must not make a message too long to pass as an argument.
    for i in "${!names[@]}"; do
      [ "$i" -lt "$MAX_NAMED_CHECKS" ] || break
      named+=("${names[i]}${urls[i]:+ (${urls[i]})}")
    done
    [ "${#names[@]}" -gt "$MAX_NAMED_CHECKS" ] && named+=("$((${#names[@]} - MAX_NAMED_CHECKS)) more")
    checks_news="checks $(join_and "${named[@]}") failed on $commit"
  fi
  [ "$running" -gt 0 ] 2>/dev/null &&
    checks_news="$checks_news, $running other check$([ "$running" -eq 1 ] || echo s) still running"
  checks_news="$checks_news: $CHECKS_ADVICE"
}

# An open PR from the open list (the columns of open_prs_of after the number).
# One of MY_LOGINS' PRs that has just gone into conflict with its base is news
# once: conflicts.tsv remembers it was told until GitHub calls the PR mergeable
# again. UNKNOWN (GitHub has not worked it out yet) changes nothing. A check of
# one of MY_LOGINS' PRs that has failed is news once, as soon as it fails, even
# while others still run (checks_note). A teammate's PR is never news this way:
# the session that mentioned it must not rebase or fix someone else's branch.
check_open() {
  local repo="$1" n="$2" updated="$3" mergeable="$4" author="$5" base="$6" merge_state="$7" head="$8" running="$9" failed="${10}"
  local note="" mine=0
  is_mine "$author" && mine=1
  [ "$base" = - ] && base="its base branch"
  case "$mergeable" in
    MERGEABLE) conflict_has "$repo" "$n" && conflict_drop "$repo" "$n" ;;
    CONFLICTING)
      if [ "$mine" -eq 1 ] && ! conflict_has "$repo" "$n"; then
        # shellcheck disable=SC2059
        note=$(printf "$CONFLICT_SUMMARY" "$base" "$base")
      fi
      ;;
  esac
  checks_now=()
  checks_news=""
  checks_had=""
  if [ "$mine" -eq 1 ] && ! checks_note "$repo" "$n" "$head" "$running" "$failed"; then
    log "reading the failed checks of $repo#$n failed; trying again next pass"
    return 1
  fi
  if [ "$checks_seeding" -eq 1 ] && [ -n "$checks_news" ]; then
    log "$repo#$n already had failed checks when failed-check notices started; recorded, not told: $checks_news"
    checks_news=""
  fi
  merge_news="" merge_ready=0 merge_next=keep pr_threads="" pr_is_mine="$mine"
  if [ "$mine" -eq 1 ] && ! merge_step "$repo" "$n" "$head" "$updated" "$merge_state" "$base" "$running" "$failed"; then
    log "reading the merge state of $repo#$n failed; trying again next pass"
    return 1
  fi
  check_pr "$repo" "$n" "$updated" "$(join_news "$(join_news "$note" "$checks_news")" "$merge_news")" || return
  [ -z "$note" ] || conflict_add "$repo" "$n"
  if [ "$merge_next" != keep ]; then
    merge_state_set "$repo" "$n" "$head" "$updated" "$merge_next" || log "could not record the merge state of $repo#$n"
    [ "$merge_ready" -eq 1 ] && event "READY_TO_MERGE $repo#$n ${head:0:7}"
  fi
  [ "$(printf '%s\n' "${checks_now[@]}" | sed '/^$/d')" = "$checks_had" ] && return 0
  checks_save "$repo" "$n" "${checks_now[@]}" || log "could not record the failed checks of $repo#$n"
  return 0
}

# "1 unresolved review thread (<who> at <where>)", or the plural, from an
# unresolved_threads_of line; nothing when there are none.
threads_phrase() {
  local count="${1%%$'\t'*}" list="${1#*$'\t'}"
  [ "$count" -gt 0 ] 2>/dev/null || return 0
  printf '%s unresolved review thread%s%s' "$count" "$([ "$count" -eq 1 ] || echo s)" "${list:+ ($list)}"
}

# merge_step <repo> <n> <head sha> <updatedAt> <merge state> <base> <running>
# <failed>: the last step of one of MY_LOGINS' PRs, once its checks are done and
# none failed. GitHub letting it merge (CLEAN) means I am told it is ready
# (merge_ready; merging is mine to do). GitHub blocking it on unresolved review
# threads, or because the branch is behind its base, means its session is told
# what blocks it (merge_news). Each is said once per head and state
# (merge_state.tsv), and BLOCKED for another reason (an approval still to come:
# stalled.sh asks for it) is recorded as waiting. Threads are asked for only
# when the PR is BLOCKED and moved since the last answer. Sets merge_next to the
# state to record, or keep. Fails when merge_state.tsv cannot be read.
merge_step() {
  local repo="$1" n="$2" head="$3" updated="$4" state="$5" base="$6" running="$7" failed="$8"
  local row had_head="" had_updated="" had_state=""
  row=$(merge_state_get "$repo" "$n") || return 1
  [ -n "$row" ] && IFS=$'\t' read -r had_head had_updated had_state _ <<<"$row"
  [ "$running" = 0 ] && [ "$failed" = - ] && [ "$head" != - ] || return 0
  case "$state" in
    CLEAN | HAS_HOOKS) merge_next=ready ;;
    BEHIND) merge_next=behind ;;
    BLOCKED)
      if [ "$had_head" = "$head" ] && [ "$had_updated" = "$updated" ] &&
        { [ "$had_state" = waiting ] || [ "$had_state" = threads ]; }; then
        merge_next="$had_state"
      elif ! pr_threads=$(unresolved_threads_of "$repo" "$n") || [ -z "$pr_threads" ]; then
        log "reading the review threads of $repo#$n failed; looking again next pass"
        pr_threads=""
        return 0
      elif [ -n "$(threads_phrase "$pr_threads")" ]; then
        merge_next=threads
      else
        merge_next=waiting
      fi
      ;;
    *) return 0 ;; # still being worked out, in conflict (told apart), a draft
  esac
  if [ "$had_head" = "$head" ] && [ "$had_state" = "$merge_next" ]; then
    # Told already; the row moves only to remember a newer updatedAt.
    [ "$had_updated" = "$updated" ] && merge_next=keep
    return 0
  fi
  case "$merge_next" in
    ready) merge_ready=1 ;;
    # shellcheck disable=SC2059
    behind) merge_news=$(printf "$BEHIND_SUMMARY" "$base" "$base") ;;
    # shellcheck disable=SC2059
    threads) merge_news=$(printf "$THREADS_BLOCK_SUMMARY" "$(threads_phrase "$pr_threads")") ;;
  esac
}

# Takes a PR off the watch list for good, without a notice.
forget_pr() {
  closed_add "$1" "$2"
  watch_drop_pr "$1" "$2"
  pending_drop "$1" "$2"
  conflict_drop "$1" "$2"
  checks_drop "$1" "$2"
  merge_state_drop "$1" "$2"
}

# The closing notice for a merged or closed PR. A merge always gets one, since
# I merge my own PRs and the session may have a step to do after it; a close by
# one of MY_LOGINS gets none.
notify_closed() {
  local repo="$1" n="$2" state="$3" closer="$4" kind=merged
  if [ "$state" = CLOSED ]; then
    kind=closed
    closer=$(closer_of "$repo" "$n") || return 1
    is_mine "$closer" && return 0
  fi
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
  local repo="$1" open status complete=0 n row updated mergeable author base merge_state head running failed
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
      IFS=$'\t' read -r _ updated mergeable author base merge_state head running failed <<<"$row"
      check_open "$repo" "$n" "$updated" "$mergeable" "$author" "$base" "$merge_state" "$head" "$running" "$failed"
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
[ "$checks_seeding" -eq 1 ] && { [ -e "$WATCH_CHECKS" ] || : >"$WATCH_CHECKS"; }
[ "$seen_seeding" -eq 1 ] && { [ -e "$WATCH_SEEN" ] || : >"$WATCH_SEEN"; }
log_no_updated_at
exit 0
