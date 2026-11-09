#!/usr/bin/env bash
# The PR update watcher's ledger and lock. Source it after lib.sh and load_config.
#
# Every file lives in $PR_UPDATES_DIR, is tab-separated, and is created by its
# first write; a missing file reads as an empty one. Columns:
#
#   sessions.tsv  short id, session id, live|retired, pid or -, startedAt ms, cwd, name
#                 (a SESSION line from session_prs.js without the SESSION word)
#   watch.tsv     repo, PR number, session id, source (created|linked|mentioned), first seen (ISO)
#   seen.tsv      repo, PR number, updatedAt last looked at, newest activity handled
#   pending.tsv   repo, PR number, session id, attempts, summary (a message not yet delivered)
#   sent.log      epoch seconds, repo, PR number, session id, delivery, result, summary
#   closed.txt    repo, PR number, closed (ISO)
#   conflicts.tsv repo, PR number, since (ISO): one of my PRs whose merge conflicts
#                 its session was told about; cleared when it is mergeable again
#   checks.tsv    repo, PR number, key, first told (ISO): a failed check on one of
#                 my PRs its session was told about, keyed by its job link (or
#                 "<name>@<link or head sha>"); a row leaves when that check stops
#                 failing. Its absence means failed-check notices never ran here:
#                 that pass records the failures without telling (checks_seeding)
#   unreachable.tsv  repo, first failure (ISO): a repository GitHub would not
#                 resolve (deleted, or hidden from the current gh account), kept
#                 until a pass reads it again, so the outage is logged once
#   scan.tsv      session id, bytes read (written by session_prs.js; watch_drop_gone
#                 removes the rows of sessions that left the listing)
#   lock/         directory holding a pid file: the pass that is running
#
# The lock here is not a RUNNING_DIR lock: those are counted as review runs.
# Rewrites go through rewrite_file (lib.sh): a temp file moved over the original,
# and the original left as it was when the read behind the rewrite fails.
# One pass at a time (watch_lock) means no two writers meet in these files.

WATCH_SESSIONS="$PR_UPDATES_DIR/sessions.tsv"
WATCH_ROWS="$PR_UPDATES_DIR/watch.tsv"
WATCH_SEEN="$PR_UPDATES_DIR/seen.tsv"
WATCH_PENDING="$PR_UPDATES_DIR/pending.tsv"
WATCH_SENT="$PR_UPDATES_DIR/sent.log"
WATCH_CLOSED="$PR_UPDATES_DIR/closed.txt"
WATCH_UNREACHABLE="$PR_UPDATES_DIR/unreachable.tsv"
WATCH_CONFLICTS="$PR_UPDATES_DIR/conflicts.tsv"
WATCH_CHECKS="$PR_UPDATES_DIR/checks.tsv"
WATCH_SCAN="$PR_UPDATES_DIR/scan.tsv"
WATCH_LOCK="$PR_UPDATES_DIR/lock"
SECONDS_PER_DAY=86400

# --- Helpers -----------------------------------------------------------------

# The arguments as one field: joined with spaces, with nothing that would end a
# column or a row.
watch_field() {
  local text="$*"
  text="${text//$'\t'/ }"
  text="${text//$'\n'/ }"
  printf '%s' "${text//$'\r'/ }"
}

# Prints a file without the rows of one PR (the first two columns).
watch_rows_without() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v repo="$2" -v n="$3" '!($1 == repo && $2 == n)' "$1"
}

# Removes the rows of one PR from a file.
watch_drop_rows() {
  [ -f "$1" ] || return 0
  rewrite_file "$1" watch_rows_without "$1" "$2" "$3"
}

# A file's rows without one PR's, then $4.
watch_rows_with() {
  watch_rows_without "$1" "$2" "$3" || return 1
  printf '%s\n' "$4"
}

# Replaces the row of one PR in a file with $4, or adds it.
watch_put_row() {
  rewrite_file "$1" watch_rows_with "$@"
}

# Prints the row of one PR from a file, if there is one.
watch_row_of() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v repo="$2" -v n="$3" '$1 == repo && $2 == n { print; exit }' "$1"
}

# The same row without its repo and number columns. One awk and no pipe, so a
# caller can tell a failed read (non-zero) from a PR with no row (empty, zero).
watch_row_rest() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v repo="$2" -v n="$3" '$1 == repo && $2 == n { sub(/^[^\t]*\t[^\t]*\t/, ""); print; exit }' "$1"
}

# --- Lock --------------------------------------------------------------------

# Takes the lock, or fails if a live pass holds it. A lock whose process is gone
# (killed by the task's time limit, a reboot) is taken over. mkdir is atomic, so
# two passes that start at once run one.
watch_lock() {
  local pid
  if ! mkdir "$WATCH_LOCK" 2>/dev/null; then
    pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    rm -rf "$WATCH_LOCK"
    mkdir "$WATCH_LOCK" 2>/dev/null || return 1
  fi
  echo "$$" >"$WATCH_LOCK/pid"
}

# Gives the lock back, but only if this shell holds it.
watch_unlock() {
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$WATCH_LOCK"
  fi
  return 0
}

# --- Sessions ----------------------------------------------------------------

# Replaces sessions.tsv with the SESSION lines on stdin, minus the SESSION word.
sessions_save() {
  rewrite_file "$WATCH_SESSIONS" awk '/^SESSION\t/ { print substr($0, 9) }'
}

# One field of a session: short, status, pid, started, cwd or name.
session_field() {
  local column
  case "$2" in
    short) column=1 ;;
    status) column=3 ;;
    pid) column=4 ;;
    started) column=5 ;;
    cwd) column=6 ;;
    name) column=7 ;;
    *) echo "no such session field: $2" >&2; return 1 ;;
  esac
  [ -f "$WATCH_SESSIONS" ] || return 0
  awk -F'\t' -v id="$1" -v column="$column" '$2 == id { print $column; exit }' "$WATCH_SESSIONS"
}

# --- Watch rows --------------------------------------------------------------

# Records that a session is watching a PR; the same three keys are kept once.
watch_add() {
  local repo="$1" n="$2" session="$3" source="$4"
  if [ -f "$WATCH_ROWS" ] &&
    awk -F'\t' -v repo="$repo" -v n="$n" -v session="$session" \
      '$1 == repo && $2 == n && $3 == session { found = 1 } END { exit !found }' "$WATCH_ROWS"; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$n" "$session" "$source" "$(date -u +%FT%TZ)" >>"$WATCH_ROWS"
}

# Forgets the watchers whose session is no longer in sessions.tsv, and how far
# their transcripts were read: a session that comes back is read from the start,
# or the PRs it named before would never be offered again. Logs one line.
watch_drop_gone() {
  local gone ids
  [ -f "$WATCH_ROWS" ] || return 0
  # "<session id> <rows>" per session that left, the kept rows in the .tmp file.
  gone=$(awk -F'\t' -v sessions="$WATCH_SESSIONS" -v kept="$WATCH_ROWS.tmp" '
    BEGIN { while ((getline line < sessions) > 0) { split(line, f, "\t"); known[f[2]] = 1 } }
    $3 in known { print > kept; next }
    { count[$3]++ }
    END { printf "" > kept; for (s in count) print s " " count[s] }' "$WATCH_ROWS") || return 1
  if [ -z "$gone" ]; then
    rm -f "$WATCH_ROWS.tmp"
    return 0
  fi
  mv "$WATCH_ROWS.tmp" "$WATCH_ROWS" || return 1
  ids=$(cut -d' ' -f1 <<<"$gone" | tr '\n' ' ')
  if [ -f "$WATCH_SCAN" ]; then
    awk -F'\t' -v ids="$ids" 'BEGIN { n = split(ids, g, " "); for (i = 1; i <= n; i++) drop[g[i]] = 1 }
      !($1 in drop)' "$WATCH_SCAN" >"$WATCH_SCAN.tmp" && mv "$WATCH_SCAN.tmp" "$WATCH_SCAN" || return 1
  fi
  log "sessions no longer listed, their watch rows dropped and their transcripts to be read again if they come back (watch rows each):" \
    "$(awk '{ printf "%s%s (%s)", sep, $1, $2; sep = ", " }' <<<"$gone")"
}

watch_drop_pr() {
  watch_drop_rows "$WATCH_ROWS" "$1" "$2"
}

# Each watched PR once, as "<repo>\t<n>".
watch_prs() {
  [ -f "$WATCH_ROWS" ] || return 0
  awk -F'\t' '!seen[$1 FS $2]++ { print $1 "\t" $2 }' "$WATCH_ROWS"
}

# The session that gets a PR's news. The one that created the PR, then the one
# that was handed a link to it, then one that only mentioned it; among equals a
# live session before a retired one, then the most recently started. Ties keep
# the earlier row.
watch_owner() {
  [ -f "$WATCH_ROWS" ] || return 0
  awk -F'\t' -v repo="$1" -v n="$2" -v sessions="$WATCH_SESSIONS" '
    BEGIN {
      rank["created"] = 3; rank["linked"] = 2; rank["mentioned"] = 1
      while ((getline line < sessions) > 0) {
        split(line, f, "\t")
        live[f[2]] = (f[3] == "live") ? 1 : 0
        started[f[2]] = f[5] + 0
      }
    }
    $1 == repo && $2 == n {
      r = rank[$4] + 0; l = live[$3] + 0; s = started[$3] + 0
      if (!best || r > br || (r == br && (l > bl || (l == bl && s > bs)))) {
        best = $3; br = r; bl = l; bs = s
      }
    }
    END { if (best) print best }' "$WATCH_ROWS"
}

# --- Seen --------------------------------------------------------------------

# "<updatedAt>\t<newest>" for a PR, or nothing.
seen_get() {
  watch_row_rest "$WATCH_SEEN" "$1" "$2"
}

seen_set() {
  watch_put_row "$WATCH_SEEN" "$1" "$2" "$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")"
}

# --- Sent --------------------------------------------------------------------

# Appends a row to sent.log: repo, n, session, delivery, result, then the summary words.
sent_record() {
  local repo="$1" n="$2" session="$3" delivery="$4" result="$5"
  shift 5
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$repo" "$n" "$session" "$delivery" "$result" \
    "$(watch_field "$@")" >>"$WATCH_SENT"
}

# How many messages reached a PR's session in the last day.
sent_last_day() {
  [ -f "$WATCH_SENT" ] || { echo 0; return 0; }
  awk -F'\t' -v repo="$1" -v n="$2" -v since="$(($(date +%s) - SECONDS_PER_DAY))" '
    $2 == repo && $3 == n && $6 == "ok" && $1 >= since { count++ }
    END { print count + 0 }' "$WATCH_SENT"
}

# --- Pending -----------------------------------------------------------------

# A message that has not been delivered yet: repo, n, session, attempts so far, summary words.
pending_set() {
  local repo="$1" n="$2" session="$3" attempts="$4"
  shift 4
  watch_put_row "$WATCH_PENDING" "$repo" "$n" \
    "$(printf '%s\t%s\t%s\t%s\t%s' "$repo" "$n" "$session" "$attempts" "$(watch_field "$@")")"
}

# "<session id>\t<attempts>\t<summary>" for a PR, or nothing.
pending_get() {
  watch_row_rest "$WATCH_PENDING" "$1" "$2"
}

pending_drop() {
  watch_drop_rows "$WATCH_PENDING" "$1" "$2"
}

# --- Closed ------------------------------------------------------------------

closed_has() {
  [ -f "$WATCH_CLOSED" ] || return 1
  awk -F'\t' -v repo="$1" -v n="$2" '$1 == repo && $2 == n { found = 1 } END { exit !found }' "$WATCH_CLOSED"
}

closed_add() {
  closed_has "$1" "$2" && return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%FT%TZ)" >>"$WATCH_CLOSED"
}

# --- Conflicts ---------------------------------------------------------------

conflict_has() {
  [ -f "$WATCH_CONFLICTS" ] || return 1
  awk -F'\t' -v repo="$1" -v n="$2" '$1 == repo && $2 == n { found = 1 } END { exit !found }' "$WATCH_CONFLICTS"
}

conflict_add() {
  conflict_has "$1" "$2" && return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%FT%TZ)" >>"$WATCH_CONFLICTS"
}

conflict_drop() {
  watch_drop_rows "$WATCH_CONFLICTS" "$1" "$2"
}

# --- Failed checks -----------------------------------------------------------

# The keys of a PR's failed checks its session was told about, one a line.
checks_known() {
  [ -f "$WATCH_CHECKS" ] || return 0
  awk -F'\t' -v repo="$1" -v n="$2" '$1 == repo && $2 == n { print $3 }' "$WATCH_CHECKS"
}

# checks_save <repo> <n> <key>...: the PR's rows become these keys, each keeping
# the time it was first told; no key drops them. A job that stops failing (it
# was re-run, or the PR moved on) leaves the file, so it stays small.
checks_save() {
  local repo="$1" n="$2" old key stamp
  shift 2
  if [ "$#" -eq 0 ]; then
    checks_drop "$repo" "$n"
    return
  fi
  if [ -f "$WATCH_CHECKS" ]; then
    old=$(awk -F'\t' -v repo="$repo" -v n="$n" '$1 == repo && $2 == n { print $3 "\t" $4 }' "$WATCH_CHECKS") || return 1
  fi
  stamp=$(date -u +%FT%TZ)
  rewrite_file "$WATCH_CHECKS" checks_rows_with "$repo" "$n" "$old" "$stamp" "$@"
}

# checks_save's new file: the other PRs' rows, then one row per key, with the
# time from <old> ("<key>\t<time>" lines) when the key had one, else <stamp>.
checks_rows_with() {
  local repo="$1" n="$2" old="$3" stamp="$4" key
  shift 4
  watch_rows_without "$WATCH_CHECKS" "$repo" "$n" || return 1
  for key in "$@"; do
    key=$(watch_field "$key")
    printf '%s\t%s\t%s\t%s\n' "$repo" "$n" "$key" \
      "$(KEY="$key" STAMP="$stamp" awk -F'\t' '$1 == ENVIRON["KEY"] { found = $2 } END { print (found ? found : ENVIRON["STAMP"]) }' <<<"$old")"
  done
}

checks_drop() {
  watch_drop_rows "$WATCH_CHECKS" "$1" "$2"
}

# --- Unreachable repositories ------------------------------------------------

unreachable_has() {
  [ -f "$WATCH_UNREACHABLE" ] || return 1
  awk -F'\t' -v repo="$1" '$1 == repo { found = 1 } END { exit !found }' "$WATCH_UNREACHABLE"
}

# Marks a repository unreachable; true only when it was not marked yet.
unreachable_mark() {
  unreachable_has "$1" && return 1
  printf '%s\t%s\n' "$1" "$(date -u +%FT%TZ)" >>"$WATCH_UNREACHABLE"
}

# Clears the mark; true only when there was one.
unreachable_clear() {
  unreachable_has "$1" || return 1
  rewrite_file "$WATCH_UNREACHABLE" awk -F'\t' -v repo="$1" '$1 != repo' "$WATCH_UNREACHABLE"
}
