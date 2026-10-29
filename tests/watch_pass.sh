#!/usr/bin/env bash
# Runs passes of scripts/watch_pr_updates.sh against stub gh and claude commands
# (tests/stubs), a copy of the made-up Claude Code home in tests/fixtures/sessions,
# and a fake inbox (tests/fake_inbox.js) for the live session aaaa1111 (pid 100).
# bbbb2222 is a retired background session. Each scenario gets its own state dir
# and stub dir, so nothing real is read, written, contacted or resumed.
#
# Needs only node.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS/.." && pwd)"
WATCHER="$ROOT/scripts/watch_pr_updates.sh"

SERVER_PID=
WORK="$(mktemp -d)"
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
# node wants a path it can open; on Windows that is the mixed form (C:/...).
WORK_DIR="$(cd "$WORK" && { pwd -W 2>/dev/null || pwd; })"
HOME_DIR="$WORK_DIR/home"
# lib.sh puts $HOME/bin and $HOME/.local/bin first on PATH, where the real gh and
# claude live; an empty HOME keeps the stubs first.
FAKE_USER="$WORK/user"
mkdir -p "$FAKE_USER"
STUB_PATH="$TESTS/stubs:$PATH"

AAAA=aaaa1111-0000-4000-8000-000000000001
BBBB=bbbb2222-0000-4000-8000-000000000002
T=$'\t'
T1=2026-01-01T00:00:00Z
T2=2026-01-02T00:00:00Z
T3=2026-01-03T00:00:00Z
# Later than any pass's "now", so they count after a silent first sight.
F1=2099-01-01T00:00:00Z
F2=2099-01-02T00:00:00Z
OLD=2020-01-01T00:00:00Z

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

found="$(HOME="$FAKE_USER" PATH="$STUB_PATH" bash -c '. "$1/scripts/lib.sh"; command -v gh; command -v claude' _ "$ROOT")"
if [ "$found" != "$TESTS/stubs/gh"$'\n'"$TESTS/stubs/claude" ]; then
  echo "FAIL the stubs are not first on PATH, so the real gh or claude would run:"
  echo "$found"
  exit 1
fi

# --- The Claude Code home ----------------------------------------------------
cp -r "$TESTS/fixtures/sessions" "$WORK/home"
sed -i "s|@HOME@|$HOME_DIR|" "$WORK/home/jobs/bbbb2222/state.json"
# bbbb2222 also owns Org/other#6.
echo '{"type":"pr-link","sessionId":"'"$BBBB"'","prNumber":6,"prUrl":"https://github.com/Org/other/pull/6","prRepository":"Org/other","timestamp":"2026-01-01T00:00:02Z"}' \
  >>"$WORK/home/elsewhere/bbbb.jsonl"
mkdir "$WORK/home/sessions"
# The folder bbbb2222 ran in; the fixture's C:\w\other does not exist.
mkdir "$WORK/other"
BBBB_CWD="$WORK_DIR/other"

RANDOM_HEX="$(node -e "process.stdout.write(require('crypto').randomBytes(16).toString('hex'))")"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) PIPE="\\\\.\\pipe\\LOCAL\\cc-msg-watch$RANDOM_HEX" ;;
  *) PIPE="$WORK_DIR/cc-msg-watch.sock" ;;
esac
# The pipe path goes through JSON.stringify so its backslashes are escaped.
write_registry() {
  node -e '
    const [dir, sid, pipe] = process.argv.slice(1);
    const fs = require("fs");
    fs.writeFileSync(dir + "/100.json", JSON.stringify({ pid: 100, sessionId: sid, messagingSocketPath: pipe }));
    fs.writeFileSync(dir + "/100." + "a".repeat(64) + ".key", JSON.stringify({ peerToken: "tok" }));
  ' "$HOME_DIR/sessions" "$AAAA" "$1"
}
write_registry "$PIPE"

RECEIVED="$WORK_DIR/received.txt"
: >"$RECEIVED"
node "$TESTS/fake_inbox.js" "$PIPE" "$RECEIVED" >"$WORK/server.out" &
SERVER_PID=$!
for _ in $(seq 50); do grep -q listening "$WORK/server.out" && break; sleep 0.1; done
if ! grep -q listening "$WORK/server.out"; then
  echo "FAIL the fake inbox did not start listening within 5 seconds"
  exit 1
fi

received_lines() { { wc -l <"$RECEIVED" 2>/dev/null || echo 0; } | tr -d ' '; }
# The sender can exit before the fake inbox has written what it read.
wait_for_received_lines() {
  for _ in $(seq 50); do
    [ "$(received_lines)" -ge "$1" ] && return
    sleep 0.1
  done
}
last_message() {
  tail -n 1 "$RECEIVED" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).message.content)'
}

# --- Scenario helpers ---------------------------------------------------------
scenario=0
# A new state dir and stub dir; the arguments are extra config.env lines.
fresh() {
  scenario=$((scenario + 1))
  STATE="$WORK/state$scenario"
  STUB_DIR="$STATE/stub"
  D="$STATE/pr_updates"
  mkdir -p "$STUB_DIR"
  cp "$WORK/home/agents.json" "$STUB_DIR/agents.json"
  set_bbbb_cwd "$BBBB_CWD"
  CONF="$STATE/config.env"
  { cat "$ROOT/config.env"; echo 'MY_LOGINS="errmakov-fuse errmakov"'; printf '%s\n' "$@"; } >"$CONF"
  repo_open "10 $T1" "11 $T1"
  other_open "5 $T1" "6 $T1"
}

set_bbbb_cwd() {
  node -e '
    const [file, cwd] = process.argv.slice(1);
    const fs = require("fs");
    const agents = JSON.parse(fs.readFileSync(file, "utf8"));
    for (const a of agents) if (a && a.id === "bbbb2222") a.cwd = cwd;
    fs.writeFileSync(file, JSON.stringify(agents));
  ' "$(cd "$STUB_DIR" && { pwd -W 2>/dev/null || pwd; })/agents.json" "$1"
}

# open_prs <repo> "<n> <updatedAt>"...
open_prs() {
  local repo="$1" out="" pr
  shift
  for pr in "$@"; do
    out="$out${out:+,}{\"number\":${pr%% *},\"updatedAt\":\"${pr#* }\"}"
  done
  echo "[$out]" >"$STUB_DIR/pr_list_${repo//\//_}.json"
}
# aaaa1111 also watches 14, 15, 18 and eeee5555 watches 30; they stay put.
repo_open() { open_prs Org/repo "$@" "14 $T1" "15 $T1" "18 $T1" "30 $T1"; }
other_open() { open_prs Org/other "$@"; }

comment() { printf '{"user":{"login":"%s"},"created_at":"%s","body":"text"}' "$1" "$2"; }
review() { printf '{"user":{"login":"%s"},"state":"%s","submitted_at":"%s","body":"text"}' "$1" "$2" "$3"; }
answer() { echo "[$2]" >"$STUB_DIR/$1"; }

run_pass() {
  HOME="$FAKE_USER" PATH="$STUB_PATH" STUB_DIR="$STUB_DIR" CLAUDE_HOME="$HOME_DIR" \
    AGENT_CODEREVIEW_CONFIG="$CONF" AGENT_CODEREVIEW_STATE="$STATE" \
    bash "$WATCHER" "$@" >"$WORK/out" 2>"$WORK/err"
  echo $? >"$WORK/status"
}
out() { cat "$WORK/out"; }
status() { cat "$WORK/status"; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
count_calls() { calls | grep -c "$1"; }
resume_lines() { calls | grep "^resume"; }
row() { awk -F'\t' -v repo="$2" -v n="$3" '$1 == repo && $2 == n' "$D/$1" 2>/dev/null; }
seen_updated() { row seen.tsv "$1" "$2" | cut -f3; }
seen_newest() { row seen.tsv "$1" "$2" | cut -f4; }
# Enrols every watched PR silently, then forgets the calls it made.
enrol() {
  run_pass
  rm -f "$STUB_DIR/calls.log"
}

# --- First sight, an update, nothing new, ignored logins -------------------------
fresh
run_pass
check "first pass: exit 0" "0" "$(status)"
check "first pass: no events" "" "$(out)"
check "first pass: seen rows for 10 and 11 at their updatedAt" "$T1 $T1" \
  "$(seen_updated Org/repo 10) $(seen_updated Org/repo 11)"
check "first pass: one gh pr list per repository" "1 1" \
  "$(count_calls '^gh pr list --repo Org/repo ') $(count_calls '^gh pr list --repo Org/other ')"
check "first pass: no gh api call" "0" "$(count_calls '^gh api')"
check "first pass: no gh pr view (every watched PR is open)" "0" "$(count_calls '^gh pr view')"

rm -f "$STUB_DIR/calls.log"
before=$(received_lines)
repo_open "10 $T2" "11 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
run_pass
wait_for_received_lines $((before + 2))
check "an update: one NOTIFIED line by inbox" \
  "NOTIFIED Org/repo#10 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "the inbox got the update message" \
  "There is an update on PR https://github.com/Org/repo/pull/10: 1 comment from samrent-infuse. Check it out whether any action is needed and proceed if it is." \
  "$(last_message)"
check "the inbox got the auth frame first" '{"type":"auth","token":"tok"}' "$(tail -n 2 "$RECEIVED" | head -n 1)"
check "sent.log has one ok row" "1" "$(awk -F'\t' '$6 == "ok"' "$D/sent.log" | wc -l | tr -d ' ')"
check "seen records the newest item handled" "$T2$T$F1" "$(seen_updated Org/repo 10)$T$(seen_newest Org/repo 10)"
check "only PR 10 was fetched" "3 0" "$(count_calls '^gh api repos/Org/repo/[a-z]*/10/') $(count_calls '/11/')"
check "the comments are asked for since the time of first sight" "1" \
  "$(count_calls "^gh api repos/Org/repo/issues/10/comments?since=20[0-9-]*T[0-9:]*Z&per_page=100$")"

rm -f "$STUB_DIR/calls.log"
run_pass
check "nothing changed: no events" "" "$(out)"
check "nothing changed: no gh api call" "0" "$(count_calls '^gh api')"

# GitHub answers the reviews (no since) and anything edited since in full, so
# the comment and a review from before the last pass come back too.
repo_open "10 $T3" "11 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1"),$(comment Errmakov-Fuse "$F2")"
answer reviews_10.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
before=$(received_lines)
run_pass
check "only my own comment is new: no events (older items are not sent again)" "" "$(out)"
check "only my own comment: seen moves to the new updatedAt" "$T3" "$(seen_updated Org/repo 10)"
check "only my own comment: the newest handled item stays" "$F1" "$(seen_newest Org/repo 10)"
sleep 0.3
check "only my own comment: nothing sent" "$before" "$(received_lines)"

# --- A retired owner is resumed ---------------------------------------------------
fresh
enrol
other_open "5 $T2" "6 $T1"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
run_pass
check "retired owner: one resume call with the whole message as one argument" \
  "resume${T}$BBBB${T}There is an update on PR https://github.com/Org/other/pull/5: a review requesting changes from samrent-infuse. Check it out whether any action is needed and proceed if it is." \
  "$(calls | grep '^resume')"
check "retired owner: NOTIFIED by resume" \
  "NOTIFIED Org/other#5 resume bbbb2222 a review requesting changes from samrent-infuse" "$(out)"
check "retired owner: resumed in the folder it ran in" "$BBBB_CWD" "$(cat "$STUB_DIR/resume_cwd")"
check "retired owner: sent.log records the resume" "resume${T}ok" "$(awk -F'\t' '$2 == "Org/other"' "$D/sent.log" | cut -f5-6)"

fresh
enrol
set_bbbb_cwd 'C:\w\gone-for-good'
other_open "5 $T2" "6 $T1"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
run_pass
check "retired owner whose folder is gone: not resumed" "" "$(resume_lines)"
check "retired owner whose folder is gone: NOT_DELIVERED" \
  "NOT_DELIVERED Org/other#5 bbbb2222 session folder is gone" "$(out)"
check "retired owner whose folder is gone: pending with one attempt" "1" "$(row pending.tsv Org/other 5 | cut -f4)"
check "retired owner whose folder is gone: logged" "1" "$(grep -c 'not resuming session .*folder is gone' "$STATE/poll.log")"
run_pass
check "folder still gone next pass: WATCH_GAVE_UP, still no resume" "WATCH_GAVE_UP Org/other#5 bbbb2222|" \
  "$(out)|$(resume_lines)"

# Review Focus 4: quotes in the message reach claude intact, as one argument.
fresh
enrol
printf 'Org/other\t5\t%s\t0\t%s\n' "$BBBB" "1 comment from o'brien about \"the loop\"" >"$D/pending.tsv"
run_pass
check "a message with quotes is resumed as one intact argument" \
  "resume${T}$BBBB${T}There is an update on PR https://github.com/Org/other/pull/5: 1 comment from o'brien about \"the loop\". Check it out whether any action is needed and proceed if it is." \
  "$(calls | grep '^resume')"

fresh
enrol
other_open "5 $T2" "6 $T2"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
answer reviews_6.json "$(review samrent-infuse APPROVED "$F1")"
run_pass
check "two updates for one retired session: one resume, for #5" "1 1" \
  "$(resume_lines | wc -l | tr -d ' ') $(resume_lines | grep -c 'pull/5:')"
check "two updates for one retired session: #6 waits in pending.tsv" \
  "Org/other${T}6${T}$BBBB${T}0${T}an approval from samrent-infuse" "$(row pending.tsv Org/other 6)"
check "two updates for one retired session: no event for #6" "0" "$(out | grep -c 'Org/other#6')"

for setting in PR_UPDATE_RESUME_RETIRED=false PR_UPDATE_MAX_RESUMES_PER_PASS=0; do
  fresh "$setting"
  enrol
  other_open "5 $T2" "6 $T1"
  answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
  run_pass
  check "$setting: no resume call" "" "$(resume_lines)"
  check "$setting: no event" "" "$(out)"
  check "$setting: the update waits in pending.tsv" "1" "$(row pending.tsv Org/other 5 | wc -l | tr -d ' ')"
done

fresh
enrol
touch "$STUB_DIR/fail_resume"
other_open "5 $T2" "6 $T1"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
run_pass
check "a failed resume: NOT_DELIVERED with claude's last line" \
  "NOT_DELIVERED Org/other#5 bbbb2222 error: no conversation found with session ID $BBBB" "$(out)"
check "a failed resume: pending with one attempt" "1" "$(row pending.tsv Org/other 5 | cut -f4)"

# --- The daily cap ------------------------------------------------------------------
fresh
enrol
for _ in 1 2 3 4 5 6; do
  printf '%s\tOrg/repo\t10\t%s\tinbox\tok\t1 comment from x\n' "$(date +%s)" "$AAAA" >>"$D/sent.log"
done
repo_open "10 $T2" "11 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
before=$(received_lines)
run_pass
check "cap reached: CAPPED_UPDATES" "CAPPED_UPDATES Org/repo#10 6" "$(out)"
sleep 0.3
check "cap reached: nothing sent" "$before" "$(received_lines)"
check "cap reached: seen advances" "$T2" "$(seen_updated Org/repo 10)"

# --- An inbox that is gone -------------------------------------------------------------
fresh
enrol
write_registry "${PIPE}-gone"
repo_open "10 $T2" "11 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
run_pass
check "inbox gone: NOT_DELIVERED with the reason" "NOT_DELIVERED Org/repo#10 aaaa1111 connect failed:" \
  "$(out | cut -d' ' -f1-5)"
check "inbox gone: pending with one attempt" "1" "$(row pending.tsv Org/repo 10 | cut -f4)"
run_pass
check "inbox still gone next pass: WATCH_GAVE_UP" "WATCH_GAVE_UP Org/repo#10 aaaa1111" "$(out)"
check "inbox still gone next pass: the pending row is gone" "" "$(row pending.tsv Org/repo 10)"
check "the given-up message is in the log, to carry by hand" "1" \
  "$(grep -c 'gave up on Org/repo#10.*1 comment from samrent-infuse' "$STATE/poll.log")"
write_registry "$PIPE"

# --- Merged and closed PRs -------------------------------------------------------------
fresh
enrol
open_prs Org/repo "10 $T1" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
echo '{"state":"MERGED","mergedBy":{"login":"samrent-infuse"}}' >"$STUB_DIR/pr_view_11.json"
before=$(received_lines)
run_pass
wait_for_received_lines $((before + 2))
check "merged by someone else: NOTIFIED by inbox" "NOTIFIED Org/repo#11 inbox aaaa1111 merged by samrent-infuse" "$(out)"
check "merged by someone else: the merge notice reached the inbox" \
  "PR https://github.com/Org/repo/pull/11 was merged. Nothing is left to do on it; clean up its worktree and branch if you still have them." \
  "$(last_message)"
check "merged: closed.txt has it" "1" "$(row closed.txt Org/repo 11 | wc -l | tr -d ' ')"
check "merged: watch.tsv no longer has it" "" "$(row watch.tsv Org/repo 11)"
rm -f "$STUB_DIR/calls.log"
run_pass
check "merged: the next pass does not look at it again" "0 " "$(count_calls 'pr view') $(out)"

fresh
enrol
open_prs Org/repo "10 $T1" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
echo '{"state":"CLOSED","mergedBy":null}' >"$STUB_DIR/pr_view_11.json"
echo '[{"event":"closed","actor":{"login":"errmakov"}},{"event":"reopened","actor":{"login":"x"}},{"event":"closed","actor":{"login":"samrent-infuse"}}]' \
  >"$STUB_DIR/timeline_11.json"
before=$(received_lines)
run_pass
wait_for_received_lines $((before + 2))
check "closed by someone else: the last closer is named" "NOTIFIED Org/repo#11 inbox aaaa1111 closed by samrent-infuse" "$(out)"
check "closed by someone else: the close notice reached the inbox" \
  "PR https://github.com/Org/repo/pull/11 was closed without merging. Nothing is left to do on it; clean up its worktree and branch if you still have them." \
  "$(last_message)"

fresh
enrol
open_prs Org/repo "11 $T1" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
echo '{"state":"MERGED","mergedBy":{"login":"Errmakov-Fuse"}}' >"$STUB_DIR/pr_view_10.json"
before=$(received_lines)
run_pass
check "merged by me: no event" "" "$(out)"
sleep 0.3
check "merged by me: no message" "$before" "$(received_lines)"
check "merged by me: closed.txt has it" "1" "$(row closed.txt Org/repo 10 | wc -l | tr -d ' ')"

fresh
enrol
other_open "6 $T1"
echo '{"state":"MERGED","mergedBy":{"login":"samrent-infuse"}}' >"$STUB_DIR/pr_view_5.json"
run_pass
check "merged, owner retired: no resume call" "" "$(resume_lines)"
check "merged, owner retired: no event" "" "$(out)"
check "merged, owner retired: closed.txt has it" "1" "$(row closed.txt Org/other 5 | wc -l | tr -d ' ')"

fresh
open_prs Org/repo "10 $T1" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
echo '{"state":"CLOSED","mergedBy":null}' >"$STUB_DIR/pr_view_11.json"
echo '[{"event":"closed","actor":{"login":"samrent-infuse"}}]' >"$STUB_DIR/timeline_11.json"
before=$(received_lines)
run_pass
check "already closed when first seen: no event" "" "$(out)"
sleep 0.3
check "already closed when first seen: no message" "$before" "$(received_lines)"
check "already closed when first seen: closed.txt has it, watch.tsv not" "1|" \
  "$(row closed.txt Org/repo 11 | wc -l | tr -d ' ')|$(row watch.tsv Org/repo 11)"
check "already closed when first seen, the open list complete: no pr view, no timeline call" "0 0" \
  "$(count_calls 'pr view') $(count_calls 'timeline')"

# A full open list (MAX_OPEN_PRS) may leave out open PRs, so a missing one is
# looked up; one never seen open still needs no timeline call.
full_list() {
  local fillers=() i
  for i in $(seq 2000 2094); do fillers+=("$i $T1"); done
  open_prs Org/repo "$@" "14 $T1" "15 $T1" "18 $T1" "30 $T1" "${fillers[@]}"
}
fresh
full_list "10 $T1"
echo '{"state":"CLOSED","mergedBy":null}' >"$STUB_DIR/pr_view_11.json"
echo '[{"event":"closed","actor":{"login":"samrent-infuse"}}]' >"$STUB_DIR/timeline_11.json"
run_pass
check "full open list, closed when first seen: one pr view, no timeline call" "1 0" \
  "$(count_calls 'pr view 11') $(count_calls 'timeline')"
check "full open list, closed when first seen: closed.txt has it" "1" "$(row closed.txt Org/repo 11 | wc -l | tr -d ' ')"
fresh
full_list "10 $T1"
echo '{"state":"OPEN","mergedBy":null}' >"$STUB_DIR/pr_view_11.json"
run_pass
check "full open list, open beyond it: still watched, not closed" "1|" \
  "$(row watch.tsv Org/repo 11 | wc -l | tr -d ' ')|$(row closed.txt Org/repo 11)"

# --- A repository gh cannot read (Review Focus 2) -----------------------------------------
fresh
enrol
touch "$STUB_DIR/fail_Org_other"
repo_open "10 $T2" "11 $T1"
other_open "5 $T2" "6 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
before=$(received_lines)
run_pass
wait_for_received_lines $((before + 2))
check "unresolvable repository: only the readable one has events" \
  "NOTIFIED Org/repo#10 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "unresolvable repository: one log line names it" "1" \
  "$(grep -c 'cannot resolve the repository Org/other' "$STATE/poll.log")"
check "unresolvable repository: nothing is resumed" "" "$(resume_lines)"
check "unresolvable repository: its watch rows are dropped" "" "$(awk -F'\t' '$1 == "Org/other"' "$D/watch.tsv")"
check "unresolvable repository: its PRs are in closed.txt" "5 6" \
  "$(awk -F'\t' '$1 == "Org/other" { print $2 }' "$D/closed.txt" | sort | tr '\n' ' ' | sed 's/ $//')"

fresh
enrol
touch "$STUB_DIR/flaky_Org_other"
repo_open "10 $T2" "11 $T1"
other_open "5 $T2" "6 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
answer reviews_5.json "$(review samrent-infuse CHANGES_REQUESTED "$F1")"
run_pass
check "gh pr list fails for a while: the other repository is processed, no event for this one" \
  "NOTIFIED Org/repo#10 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "gh pr list fails for a while: its watch rows are kept" "5 6" \
  "$(awk -F'\t' '$1 == "Org/other" { print $2 }' "$D/watch.tsv" | sort | tr '\n' ' ' | sed 's/ $//')"
check "gh pr list fails for a while: logged" "1" "$(grep -c 'listing the open PRs of Org/other failed' "$STATE/poll.log")"

# #10 comes before #11 in watch.tsv.
fresh
enrol
open_prs Org/repo "11 $T2" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
touch "$STUB_DIR/missing_10"
answer comments_11.json "$(comment samrent-infuse "$F1")"
run_pass
check "a PR GitHub cannot find does not hold up the next one" \
  "NOTIFIED Org/repo#11 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "a PR GitHub cannot find is dropped" "|1" "$(row watch.tsv Org/repo 10)|$(row closed.txt Org/repo 10 | wc -l | tr -d ' ')"
check "a PR GitHub cannot find is logged once" "1" "$(grep -c 'Org/repo#10 does not exist' "$STATE/poll.log")"

fresh
enrol
open_prs Org/repo "11 $T2" "14 $T1" "15 $T1" "18 $T1" "30 $T1"
touch "$STUB_DIR/fail_view_10"
answer comments_11.json "$(comment samrent-infuse "$F1")"
run_pass
check "a PR gh fails to read does not hold up the next one" \
  "NOTIFIED Org/repo#11 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "a PR gh fails to read stays watched, not closed" "1|" \
  "$(row watch.tsv Org/repo 10 | wc -l | tr -d ' ')|$(row closed.txt Org/repo 10)"
check "a PR gh fails to read is logged" "1" "$(grep -c 'reading Org/repo#10 from GitHub failed' "$STATE/poll.log")"

# --- Dry run and backfill ---------------------------------------------------------------
fresh
enrol
repo_open "10 $T2" "11 $T1"
answer comments_10.json "$(comment samrent-infuse "$F1")"
ledger_before="$(cd "$D" && ls -la && cat seen.tsv watch.tsv scan.tsv)"
before=$(received_lines)
run_pass --dry-run
check "dry run: exit 0" "0" "$(status)"
check "dry run: a DRY_RUN line names the PR and the session" \
  "DRY_RUN NOTIFIED Org/repo#10 inbox aaaa1111 1 comment from samrent-infuse" "$(out)"
check "dry run: the comments were still read" "1" "$(count_calls '^gh api repos/Org/repo/issues/10/comments')"
check "dry run: no sent.log" "absent" "$([ -e "$D/sent.log" ] && echo present || echo absent)"
check "dry run: the ledger is unchanged" "$ledger_before" "$(cd "$D" && ls -la && cat seen.tsv watch.tsv scan.tsv)"
sleep 0.3
check "dry run: nothing sent" "$before" "$(received_lines)"

fresh
answer reviews_10.json "$(review samrent-infuse APPROVED "$OLD")"
before=$(received_lines)
run_pass --backfill
wait_for_received_lines $((before + 2))
check "backfill: a review waiting before first sight is news" \
  "NOTIFIED Org/repo#10 inbox aaaa1111 an approval from samrent-infuse" "$(out)"
check "backfill: the comments are asked for without since" "1" \
  "$(count_calls '^gh api repos/Org/repo/issues/10/comments?per_page=100$')"

# --- Pending rows are retried first ----------------------------------------------------------
fresh
enrol
printf 'Org/repo\t10\t%s\t0\t2 comments from samrent-infuse\n' "$BBBB" >"$D/pending.tsv"
before=$(received_lines)
run_pass
wait_for_received_lines $((before + 2))
check "a pending update goes to the PR's current owner" \
  "NOTIFIED Org/repo#10 inbox aaaa1111 2 comments from samrent-infuse" "$(out)"
check "and leaves pending.tsv" "" "$(row pending.tsv Org/repo 10)"

# --- Failures and switches ------------------------------------------------------------------
fresh
enrol
watch_before="$(cat "$D/watch.tsv" "$D/sessions.tsv")"
touch "$STUB_DIR/fail_agents"
run_pass
check "claude agents fails: WATCH_FAILED" "WATCH_FAILED" "$(out | cut -d' ' -f1)"
check "claude agents fails: exit 1" "1" "$(status)"
check "claude agents fails: the ledger keeps its sessions and watch rows" "$watch_before" "$(cat "$D/watch.tsv" "$D/sessions.tsv")"

rm "$STUB_DIR/fail_agents"
echo '[]' >"$STUB_DIR/agents.json"
run_pass
check "no session listed: WATCH_FAILED" "WATCH_FAILED" "$(out | cut -d' ' -f1)"
check "no session listed: exit 1" "1" "$(status)"
check "no session listed: the ledger keeps its sessions and watch rows" "$watch_before" "$(cat "$D/watch.tsv" "$D/sessions.tsv")"

fresh
mkdir -p "$D/lock"
echo "$$" >"$D/lock/pid"
run_pass
check "another pass holds the lock: exit 0, no events" "0 " "$(status) $(out)"
check "another pass holds the lock: no calls" "" "$(calls)"

fresh PR_UPDATE_ENABLED=false
run_pass
check "PR_UPDATE_ENABLED=false: exit 0, no output" "0 " "$(status) $(out)"
check "PR_UPDATE_ENABLED=false: no calls" "absent" "$([ -e "$STUB_DIR/calls.log" ] && echo present || echo absent)"

fresh PR_UPDATE_ENABLED=ON
run_pass
check "PR_UPDATE_ENABLED=ON runs a pass" "1" "$(count_calls '^claude agents')"

exit "$failed"
