#!/usr/bin/env bash
# Checks the state-file helpers in scripts/lib.sh: rewrite_file, the state-file
# lock, and count_attempt run by parallel review runs. Uses a temp state dir.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENT_CODEREVIEW_STATE="$TMP/state"
# shellcheck source=/dev/null
. "$TESTS/../scripts/lib.sh"
mkdir -p "$STATE_DIR"
touch "$ATTEMPTS" "$LOG"

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
temp_files() { ls "$STATE_DIR" | grep -c '\.tmp$'; }

# --- rewrite_file -------------------------------------------------------------------
F="$STATE_DIR/f.txt"
printf 'one\ntwo\n' >"$F"
half_then_fail() { echo partial; return 2; }
rewrite_file "$F" half_then_fail
check "rewrite_file with a failing command: fails, the file is as it was, no temp file" "1|one two|0" \
  "$?|$(tr '\n' ' ' <"$F" | sed 's/ $//')|$(temp_files)"
rewrite_file "$F" grep -v one "$F"
check "rewrite_file with a command that works: the file is its output" "0|two|0" "$?|$(cat "$F")|$(temp_files)"

# --- The lock -----------------------------------------------------------------------
lock_state_file "$F"
check "lock_state_file takes a free lock" "0" "$?"
start=$(date +%s)
STATE_LOCK_WAIT_SECONDS=2
lock_state_file "$F"
check "a held lock is not taken" "1" "$?"
check "the wait is bounded by STATE_LOCK_WAIT_SECONDS" "yes" "$([ $(($(date +%s) - start)) -lt 20 ] && echo yes || echo no)"
STATE_LOCK_WAIT_SECONDS=30
touch -d '1 minute ago' "$F.lock"
lock_state_file "$F"
check "a lock left by a dead holder is taken over" "0" "$?"
unlock_state_file "$F"
check "unlock_state_file frees it" "absent" "$([ -e "$F.lock" ] && echo present || echo absent)"

# --- count_attempt ------------------------------------------------------------------
check "the first attempt of a key is 1" "1|1" "$(count_attempt 10@a)|$(attempts_of 10@a)"
check "the next is 2, and another key starts at 1" "2|1" "$(count_attempt 10@a)|$(count_attempt 11@b)"

# Parallel review runs (MAX_PARALLEL_REVIEWS is 3 in the example; this is more):
# none loses another's row or increment.
for i in $(seq 6); do count_attempt "2$i@p" >/dev/null & done
for i in $(seq 4); do count_attempt 30@same >/dev/null & done
wait
check "parallel runs on different keys: every key has its row" "6" "$(grep -c '^2[0-9]*@p 1$' "$ATTEMPTS")"
check "parallel runs on one key: every run counted" "4" "$(attempts_of 30@same)"
check "parallel runs: none had to go uncounted" "0" "$(grep -c 'are not counted' "$LOG")"
check "parallel runs: the earlier keys kept, no temp file or lock left" "2|1|0|absent" \
  "$(attempts_of 10@a)|$(attempts_of 11@b)|$(temp_files)|$([ -e "$ATTEMPTS.lock" ] && echo present || echo absent)"

before=$(cat "$ATTEMPTS")
check "a failed read: the run is attempt 1 and goes uncounted, the file as it was" "1|$before" \
  "$(attempts_of() { return 2; }; count_attempt 10@a)|$(cat "$ATTEMPTS")"
check "a failed read is logged" "1" "$(grep -c 'reading the attempts of 10@a failed' "$LOG")"

mkdir "$ATTEMPTS.lock"
before=$(cat "$ATTEMPTS")
check "the lock stays held: the run is the next attempt, uncounted, the file as it was, logged" "3|$before|1" \
  "$(STATE_LOCK_WAIT_SECONDS=1; count_attempt 10@a)|$(cat "$ATTEMPTS")|$(grep -c 'attempts of 10@a are not counted' "$LOG")"
rmdir "$ATTEMPTS.lock"

exit "$failed"
