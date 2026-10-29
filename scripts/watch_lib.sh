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
#   scan.tsv      session id, bytes read (written by session_prs.js, not by this file)
#   lock/         directory holding a pid file: the pass that is running
#
# The lock here is not a RUNNING_DIR lock: those are counted as review runs.
# Rewrites go to a .tmp file and are moved over the original, as count_attempt does.
# One pass at a time (watch_lock) means no two writers meet in these files.

WATCH_SESSIONS="$PR_UPDATES_DIR/sessions.tsv"
WATCH_ROWS="$PR_UPDATES_DIR/watch.tsv"
WATCH_SEEN="$PR_UPDATES_DIR/seen.tsv"
WATCH_PENDING="$PR_UPDATES_DIR/pending.tsv"
WATCH_SENT="$PR_UPDATES_DIR/sent.log"
WATCH_CLOSED="$PR_UPDATES_DIR/closed.txt"
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
  watch_rows_without "$1" "$2" "$3" >"$1.tmp" && mv "$1.tmp" "$1"
}

# Replaces the row of one PR in a file with $4, or adds it.
watch_put_row() {
  { watch_rows_without "$1" "$2" "$3"; printf '%s\n' "$4"; } >"$1.tmp" && mv "$1.tmp" "$1"
}

# Prints the row of one PR from a file, if there is one.
watch_row_of() {
  [ -f "$1" ] || return 0
  awk -F'\t' -v repo="$2" -v n="$3" '$1 == repo && $2 == n { print; exit }' "$1"
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
  awk '/^SESSION\t/ { print substr($0, 9) }' >"$WATCH_SESSIONS.tmp" && mv "$WATCH_SESSIONS.tmp" "$WATCH_SESSIONS"
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

# Forgets the watchers whose session is no longer in sessions.tsv.
watch_drop_gone() {
  [ -f "$WATCH_ROWS" ] || return 0
  awk -F'\t' -v sessions="$WATCH_SESSIONS" '
    BEGIN { while ((getline line < sessions) > 0) { split(line, f, "\t"); known[f[2]] = 1 } }
    $3 in known' "$WATCH_ROWS" >"$WATCH_ROWS.tmp" && mv "$WATCH_ROWS.tmp" "$WATCH_ROWS"
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
  watch_row_of "$WATCH_SEEN" "$1" "$2" | cut -f3-4
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
  watch_row_of "$WATCH_PENDING" "$1" "$2" | cut -f3-5
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
