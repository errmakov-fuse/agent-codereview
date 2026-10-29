#!/usr/bin/env bash
# Checks the PR update watcher's ledger and lock (scripts/watch_lib.sh) against a
# temp state dir, so nothing real is touched.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_CODEREVIEW_STATE="$TMP/state"

# shellcheck source=/dev/null
. "$TESTS/../scripts/lib.sh"
# shellcheck source=/dev/null
. "$TESTS/../scripts/watch_lib.sh"
load_config || exit 1

failed=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
    return
  fi
  failed=1
  echo "FAIL $name"
  echo "--- expected"
  echo "$expected"
  echo "--- actual"
  echo "$actual"
}

T=$'\t'
D="$PR_UPDATES_DIR"

# A pid that is not running.
dead=99999
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done

# --- Lock ----------------------------------------------------------------------
watch_lock; check "the first watch_lock takes the lock" "0" "$?"
watch_lock; check "a second watch_lock while it is held fails" "1" "$?"
echo "$dead" >"$D/lock/pid"
watch_lock; check "a lock whose pid is dead is taken over" "0" "$?"
check "the takeover writes this shell's pid" "$$" "$(cat "$D/lock/pid")"
echo "$dead" >"$D/lock/pid"
watch_unlock
check "watch_unlock leaves a lock that is not ours" "yes" "$([ -d "$D/lock" ] && echo yes || echo no)"
echo "$$" >"$D/lock/pid"
watch_unlock
check "watch_unlock removes our own lock" "no" "$([ -d "$D/lock" ] && echo yes || echo no)"
watch_unlock; check "watch_unlock with no lock is harmless" "0" "$?"

# --- Sessions ------------------------------------------------------------------
printf 'SESSION\ta1\tAAAA\tlive\t123\t200\t/c/my repo\tfirst name\nSESSION\tb2\tBBBB\tretired\t-\t300\t/c/other\tsecond name here\n' | sessions_save
check "session_field status of B" "retired" "$(session_field BBBB status)"
check "session_field short of A" "a1" "$(session_field AAAA short)"
check "session_field pid of A" "123" "$(session_field AAAA pid)"
check "session_field pid of B" "-" "$(session_field BBBB pid)"
check "session_field started of B" "300" "$(session_field BBBB started)"
check "session_field cwd keeps spaces" "/c/my repo" "$(session_field AAAA cwd)"
check "session_field name keeps spaces" "second name here" "$(session_field BBBB name)"
check "session_field of an unknown session is empty" "" "$(session_field ZZZZ name)"
check "sessions.tsv has no SESSION word" "a1${T}AAAA${T}live${T}123${T}200${T}/c/my repo${T}first name" "$(head -n 1 "$D/sessions.tsv")"

# --- Watch rows ----------------------------------------------------------------
watch_add Org/r 1 AAAA created
watch_add Org/r 1 AAAA created
watch_add Org/r 1 BBBB created
watch_add Org/r 2 BBBB mentioned
check "watch.tsv has 3 rows (the duplicate is skipped)" "3" "$(wc -l <"$D/watch.tsv" | tr -d ' ')"
check "a watch row has repo, n, session, source, time" "5" "$(head -n 1 "$D/watch.tsv" | awk -F'\t' '{ print NF }')"
check "watch_prs prints each PR once" "Org/r${T}1
Org/r${T}2" "$(watch_prs)"
check "watch_owner: both created, the live one wins" "AAAA" "$(watch_owner Org/r 1)"

watch_add Org/r 3 BBBB created
watch_add Org/r 3 AAAA mentioned
check "watch_owner: created wins over live" "BBBB" "$(watch_owner Org/r 3)"

watch_add Org/r 4 AAAA mentioned
watch_add Org/r 4 BBBB linked
check "watch_owner: linked beats mentioned" "BBBB" "$(watch_owner Org/r 4)"
watch_add Org/r 4 CCCC created
check "watch_owner: created beats linked" "CCCC" "$(watch_owner Org/r 4)"

printf 'SESSION\td4\tDDDD\tretired\t-\t100\t/c/d\td\nSESSION\te5\tEEEE\tretired\t-\t900\t/c/e\te\n' | sessions_save
watch_add Org/r 5 DDDD created
watch_add Org/r 5 EEEE created
check "watch_owner: both retired, the later start wins" "EEEE" "$(watch_owner Org/r 5)"
check "watch_owner of an unwatched PR is empty" "" "$(watch_owner Org/r 99)"

printf 'SESSION\ta1\tAAAA\tlive\t123\t200\t/c/my repo\tfirst name\n' | sessions_save
printf 'AAAA\t500\nBBBB\t600\nCCCC\t700\nDDDD\t800\nZZZZ\t900\n' >"$D/scan.tsv"
watch_drop_gone
check "watch_drop_gone keeps only rows of known sessions" "Org/r${T}1
Org/r${T}3
Org/r${T}4" "$(watch_prs)"
check "watch_drop_gone drops the scan rows of the sessions it dropped, and keeps the rest" "AAAA${T}500
ZZZZ${T}900" "$(cat "$D/scan.tsv")"
check "watch_drop_gone logs one line with the rows per session" "1 1 1" \
  "$(grep -c 'sessions no longer listed' "$LOG") $(grep -c 'BBBB (4)' "$LOG") $(grep -c 'DDDD (1)' "$LOG")"
watch_drop_gone
check "watch_drop_gone with nothing to drop logs nothing more" "1" "$(grep -c 'sessions no longer listed' "$LOG")"
watch_drop_pr Org/r 1
check "watch_drop_pr removes every row of that PR" "Org/r${T}3
Org/r${T}4" "$(watch_prs)"

# --- Seen ----------------------------------------------------------------------
check "seen_get with no row is empty" "" "$(seen_get Org/r 1)"
seen_set Org/r 1 t1 n1
seen_set Org/r 1 t2 n2
seen_set Org/r 2 t9 n9
check "seen_get prints updatedAt and newest" "t2${T}n2" "$(seen_get Org/r 1)"
check "seen_set replaces the row" "2" "$(wc -l <"$D/seen.tsv" | tr -d ' ')"
check "seen_get does not match a PR number prefix" "" "$(seen_get Org/r 9)"

# --- Sent ----------------------------------------------------------------------
sent_record Org/r 1 AAAA inbox ok 2 comments from x
sent_record Org/r 1 AAAA inbox ok "2 comments from x"
sent_record Org/r 1 AAAA inbox failed "2 comments from x"
sent_record Org/r 2 AAAA inbox ok "other PR"
check "sent_last_day counts ok rows of that PR" "2" "$(sent_last_day Org/r 1)"
check "sent_last_day is 0 for a PR never sent to" "0" "$(sent_last_day Org/r 7)"
check "sent.log row layout" "7" "$(head -n 1 "$D/sent.log" | awk -F'\t' '{ print NF }')"
check "sent_record joins the summary words" "2 comments from x" "$(head -n 1 "$D/sent.log" | cut -f7)"
printf '%s\tOrg/r\t1\tAAAA\tinbox\tok\told\n' "$(($(date +%s) - 2 * 86400))" >>"$D/sent.log"
check "a sent.log row from 2 days ago is not counted" "2" "$(sent_last_day Org/r 1)"

# --- Pending -------------------------------------------------------------------
pending_set Org/r 1 AAAA 1 summary words
check "pending_get prints session, attempts, summary" "AAAA${T}1${T}summary words" "$(pending_get Org/r 1)"
pending_set Org/r 1 AAAA 2 summary words
pending_set Org/r 2 BBBB 1 other
check "pending_get after a second pending_set" "AAAA${T}2${T}summary words" "$(pending_get Org/r 1)"
check "pending_set replaces the row" "2" "$(wc -l <"$D/pending.tsv" | tr -d ' ')"
pending_drop Org/r 1
check "pending_drop removes the row" "" "$(pending_get Org/r 1)"
check "pending_drop leaves other PRs" "BBBB${T}1${T}other" "$(pending_get Org/r 2)"

# --- Closed --------------------------------------------------------------------
closed_has Org/r 1; check "closed_has before closed_add is false" "1" "$?"
closed_add Org/r 1
closed_has Org/r 1; check "closed_has after closed_add is true" "0" "$?"
closed_has Org/r 10; check "closed_has does not match a number prefix" "1" "$?"
closed_add Org/r 1
check "closed_add twice keeps one row" "1" "$(wc -l <"$D/closed.txt" | tr -d ' ')"

# --- Unreachable repositories ----------------------------------------------------
unreachable_clear Org/r; check "unreachable_clear with no mark is false" "1" "$?"
unreachable_mark Org/r; check "the first unreachable_mark is true" "0" "$?"
unreachable_mark Org/r; check "a second unreachable_mark is false" "1" "$?"
unreachable_mark Org/s
check "a mark is the repo and an ISO time, once per repo" "1 1" \
  "$(grep -c "^Org/r$T" "$D/unreachable.tsv") $(grep -cE "^Org/s$T[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$" "$D/unreachable.tsv")"
unreachable_clear Org/r; check "unreachable_clear of a mark is true" "0" "$?"
check "unreachable_clear leaves other repositories" "Org/s" "$(cut -f1 "$D/unreachable.tsv")"

exit "$failed"
