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
#
# A live session gets the message in its inbox (send_to_session.js). A retired
# background session is woken with `claude --bg --resume <session id> <message>`,
# at most PR_UPDATE_MAX_RESUMES_PER_PASS a pass and once per session a pass,
# and only while PR_UPDATE_RESUME_RETIRED is on; otherwise its update waits in
# pending.tsv. At most PR_UPDATE_MAX_PER_PR_PER_DAY messages per PR a day; a
# message that fails twice is dropped.
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
PER_PAGE=100

# Node snippets for the gh answers (Git Bash has no jq).
READ_STDIN='const data = JSON.parse(require("fs").readFileSync(0, "utf8"));'
PARSE_PR_LIST="$READ_STDIN"'
process.stdout.write(data.map((pr) => pr.number + "\t" + pr.updatedAt + "\n").join(""));'
PARSE_PR_VIEW="$READ_STDIN"'
process.stdout.write((data.state || "") + "\t" + ((data.mergedBy && data.mergedBy.login) || "") + "\n");'
PARSE_CLOSER="$READ_STDIN"'
const closed = data.filter((e) => e && e.event === "closed").pop();
process.stdout.write(((closed && closed.actor && closed.actor.login) || "") + "\n");'

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
  sessions_save <<<"$listing"
  while IFS=$'\t' read -r kind repo n session source; do
    [ "$kind" = PR ] || continue
    closed_has "$repo" "$n" && continue
    watch_add "$repo" "$n" "$session" "$source"
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
# (an update stays pending) or skip (a closing notice for a retired session).
route_for() {
  local owner="$1" kind="$2"
  if [ "$(session_field "$owner" status)" = live ]; then
    echo inbox
  elif [ "$kind" != update ]; then
    echo skip
  elif can_resume "$owner"; then
    echo resume
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
# ran in. The message is one argument; nothing here passes through a shell.
send_resume() {
  local owner="$1" message="$2" cwd out
  cwd=$(session_field "$owner" cwd)
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    log "the folder of session $owner is gone ($cwd); resuming it from $ROOT"
    cwd="$ROOT"
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

# A failed update: one more attempt in pending.tsv, or given up after the last.
count_failure() {
  local repo="$1" n="$2" owner="$3" short="$4" summary="$5" why="$6" attempts
  attempts=$(pending_get "$repo" "$n" | cut -f2)
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
  message=$(compose_message "$kind" "$repo" "$n" "$summary")
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

# deliver <repo> <n> <summary> <update|merged|closed>
deliver() {
  local repo="$1" n="$2" summary="$3" kind="$4" count owner route attempts
  if [ "$kind" = update ]; then
    count=$(sent_last_day "$repo" "$n")
    if [ "$count" -ge "$PR_UPDATE_MAX_PER_PR_PER_DAY" ]; then
      log "$repo#$n had $count messages in the last day; not forwarded: $summary"
      pending_drop "$repo" "$n"
      event "CAPPED_UPDATES $repo#$n $count"
      return 0
    fi
  fi
  owner=$(watch_owner "$repo" "$n")
  if [ -z "$owner" ]; then
    log "$repo#$n has no session watching it any more; dropped: $summary"
    pending_drop "$repo" "$n"
    return 0
  fi
  route=$(route_for "$owner" "$kind")
  case "$route" in
    inbox | resume) send_message "$repo" "$n" "$owner" "$route" "$summary" "$kind" ;;
    wait)
      attempts=$(pending_get "$repo" "$n" | cut -f2)
      pending_set "$repo" "$n" "$owner" "${attempts:-0}" "$summary"
      log "$repo#$n waits: session $owner is retired and cannot be resumed in this pass"
      ;;
    skip) log "$repo#$n $summary; session $owner is retired, so it gets no notice" ;;
  esac
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
# Fails only when gh does; a bad answer skips this PR for this pass.
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
  { read -r newest; read -r summary; } <<<"$result"
  [ "$newest" = - ] && newest="${since:-$(now)}"
  seen_set "$repo" "$n" "$updated" "$newest"
  [ -n "$summary" ] || return 0
  old=$(pending_get "$repo" "$n" | cut -f3)
  [ -n "$old" ] && summary="$old; then $summary"
  deliver "$repo" "$n" "$summary" update
  return 0
}

# An open PR: enrolled on first sight, read when its updatedAt moved.
check_pr() {
  local repo="$1" n="$2" updated="$3" seen
  seen=$(seen_get "$repo" "$n")
  if [ -z "$seen" ]; then
    if [ "$backfill" -eq 1 ]; then
      fetch_updates "$repo" "$n" "$updated" ""
      return
    fi
    seen_set "$repo" "$n" "$updated" "$(now)"
    return 0
  fi
  [[ "$updated" > "${seen%%$'\t'*}" ]] || return 0
  fetch_updates "$repo" "$n" "$updated" "${seen#*$'\t'}"
}

# Who closed a PR: the actor of its last "closed" timeline event, or nothing.
closer_of() {
  local timeline
  timeline=$(gh api "repos/$1/issues/$2/timeline?per_page=$PER_PAGE" 2>>"$LOG" </dev/null) || return 1
  printf '%s' "$timeline" | node -e "$PARSE_CLOSER" 2>>"$LOG" || echo ""
}

# A watched PR missing from the open list. Fails only when gh does.
settle_closed() {
  local repo="$1" n="$2" view state merger kind closer
  if ! closed_has "$repo" "$n"; then
    view=$(gh pr view "$n" --repo "$repo" --json state,mergedBy 2>>"$LOG" </dev/null) || return 1
    view=$(printf '%s' "$view" | node -e "$PARSE_PR_VIEW" 2>>"$LOG")
    state="${view%%$'\t'*}"
    merger="${view#*$'\t'}"
    case "$state" in
      OPEN) return 0 ;; # beyond the first MAX_OPEN_PRS of the open list
      MERGED) kind=merged closer="$merger" ;;
      CLOSED)
        kind=closed
        closer=$(closer_of "$repo" "$n") || return 1
        ;;
      *)
        log "$repo#$n has state '$state'; looking again next pass"
        return 0
        ;;
    esac
    if [ -n "$(seen_get "$repo" "$n")" ] && ! is_mine "$closer"; then
      deliver "$repo" "$n" "$kind${closer:+ by $closer}" "$kind"
    fi
    closed_add "$repo" "$n"
  fi
  watch_drop_pr "$repo" "$n"
  pending_drop "$repo" "$n"
}

# One gh pr list for a repository, then each of its watched PRs. A gh failure
# skips the rest of the repository for this pass.
check_repo() {
  local repo="$1" list open n updated
  if ! list=$(gh pr list --repo "$repo" --state open --limit "$MAX_OPEN_PRS" --json number,updatedAt 2>>"$LOG" </dev/null) ||
    ! open=$(printf '%s' "$list" | node -e "$PARSE_PR_LIST" 2>>"$LOG"); then
    log "listing the open PRs of $repo failed; its PRs wait for the next pass"
    return 0
  fi
  for n in $(watch_prs | awk -F'\t' -v repo="$repo" '$1 == repo { print $2 }'); do
    updated=$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' <<<"$open")
    if [ -z "$updated" ]; then
      settle_closed "$repo" "$n" && continue
    else
      check_pr "$repo" "$n" "$updated" && continue
    fi
    log "reading $repo#$n from GitHub failed; the rest of $repo waits for the next pass"
    return 0
  done
}

list_sessions || exit 1
retry_pending
for repo in $(watch_prs | awk -F'\t' '!seen[$1]++ { print $1 }'); do
  check_repo "$repo"
done
exit 0
