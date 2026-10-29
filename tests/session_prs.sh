#!/usr/bin/env bash
# Runs scripts/session_prs.js over the made-up Claude Code home in
# tests/fixtures/sessions and checks which sessions it lists and which PRs it
# finds in their transcripts, across a first run, a repeat run, and a run after
# a transcript grew.
#
# The fixture is copied to a temp dir first, so scan.tsv starts empty and the
# fixture itself is never changed. Needs only node.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS/../scripts/session_prs.js"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$TESTS/fixtures/sessions" "$WORK/home"
mkdir "$WORK/state"
# node wants a path it can open; on Windows that is the mixed form (C:/...).
HOME_DIR="$(cd "$WORK/home" && { pwd -W 2>/dev/null || pwd; })"
STATE="$(cd "$WORK/state" && { pwd -W 2>/dev/null || pwd; })"
# The job state names the transcript by absolute path, which is only known now.
sed -i "s|@HOME@|$HOME_DIR|" "$WORK/home/jobs/bbbb2222/state.json"

AAAA=aaaa1111-0000-4000-8000-000000000001
BBBB=bbbb2222-0000-4000-8000-000000000002
DDDD=dddd4444-0000-4000-8000-000000000004
EEEE=eeee5555-0000-4000-8000-000000000005
AAAA_FILE="$HOME_DIR/projects/C--w-repo--claude-worktrees-HUB-1-x/$AAAA.jsonl"
T=$'\t'

run() {
  CLAUDE_HOME="$HOME_DIR" STATE_DIR="$STATE" node "$SCRIPT" < "$HOME_DIR/agents.json" 2>"$WORK/stderr"
  echo $? > "$WORK/status"
}

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

sessions() { grep '^SESSION' <<<"$1" | cut -f1-5 | LC_ALL=C sort; }
prs() { grep '^PR' <<<"$1" | LC_ALL=C sort; }

expected_sessions="SESSION${T}aaaa1111${T}$AAAA${T}live${T}100
SESSION${T}bbbb2222${T}$BBBB${T}retired${T}-
SESSION${T}dddd4444${T}$DDDD${T}live${T}400
SESSION${T}eeee5555${T}$EEEE${T}live${T}500"

first="$(run)"
check "a null and a non-object entry in the list do not stop the run" "0" "$(cat "$WORK/status")"
check "the two bad entries are skipped with a note each on stderr" \
  "2" "$(grep -c 'skipping an entry' "$WORK/stderr")"
check "first run lists live and retired sessions, not ended interactive ones" \
  "$expected_sessions" "$(sessions "$first")"
check "name is the last field and may contain spaces; a missing name is -" \
  "HUB-1 fix thing
other work
-
broken job state" "$(grep '^SESSION' <<<"$first" | LC_ALL=C sort | cut -f8)"
check "cwd and start time are printed" \
  "1700000000000${T}C:\\w\\repo\\.claude\\worktrees\\HUB-1_x" \
  "$(grep "^SESSION${T}aaaa1111" <<<"$first" | cut -f6,7)"
check "first run ranks sources, and finds no row for 12 (a table), 16 (assistant turn), 17 (4 lines), 19 (bad JSON line)" \
  "PR${T}Org/other${T}5${T}$BBBB${T}linked
PR${T}Org/repo${T}10${T}$AAAA${T}linked
PR${T}Org/repo${T}11${T}$AAAA${T}mentioned
PR${T}Org/repo${T}14${T}$AAAA${T}created
PR${T}Org/repo${T}15${T}$AAAA${T}created
PR${T}Org/repo${T}18${T}$AAAA${T}linked
PR${T}Org/repo${T}30${T}$EEEE${T}linked" "$(prs "$first")"
check "a session whose transcript is missing is still listed, with a note on stderr" \
  "1" "$(grep -c 'dddd4444' "$WORK/stderr")"
check "an unreadable job state is noted on stderr and the project path is used instead" \
  "1" "$(grep -c 'eeee5555: unreadable job state' "$WORK/stderr")"
check "scan.tsv has a row per scanned transcript only" \
  "$AAAA
$BBBB
$EEEE" "$(cut -f1 "$STATE/scan.tsv" | LC_ALL=C sort)"
# The last line of aaaa's transcript has no newline yet, so the offset stops before it.
partial="$(tail -n 1 "$AAAA_FILE")"
check "the offset stops before the unfinished last line" \
  "$(( $(wc -c < "$AAAA_FILE") - ${#partial} ))" "$(grep "^$AAAA" "$STATE/scan.tsv" | cut -f2)"

second="$(run)"
check "second run lists the same sessions" "$expected_sessions" "$(sessions "$second")"
check "second run finds nothing new" "" "$(prs "$second")"

# The unfinished last line of aaaa's transcript (a pr-link for #99 cut off in the
# middle of "prRepository") is finished by the session, which then adds one for
# #13. Only a scan that restarted at the beginning of that line can find #99.
printf '%s\n%s\n' 'sitory":"Org/repo"}' \
  "{\"type\":\"pr-link\",\"sessionId\":\"$AAAA\",\"prNumber\":13,\"prUrl\":\"https://github.com/Org/repo/pull/13\",\"prRepository\":\"Org/repo\"}" \
  >> "$AAAA_FILE"
third="$(run)"
check "third run finds the finished line and the new one, and nothing else" \
  "PR${T}Org/repo${T}13${T}$AAAA${T}linked
PR${T}Org/repo${T}99${T}$AAAA${T}linked" "$(prs "$third")"

# A transcript that shrank (rotated) is scanned again from the start.
printf '%s\n' "{\"type\":\"pr-link\",\"sessionId\":\"$AAAA\",\"prNumber\":20,\"prRepository\":\"Org/repo\"}" \
  > "$AAAA_FILE"
fourth="$(run)"
check "a transcript shorter than its offset is rescanned from the start" \
  "PR${T}Org/repo${T}20${T}$AAAA${T}linked" "$(prs "$fourth")"

exit "$failed"
