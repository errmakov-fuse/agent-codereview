# PR Update Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A script in the five-minute pass that tells a Claude Code session when somebody comments on a PR it owns, resuming the session if it is retired.

**Architecture:** One bash orchestrator (`scripts/watch_pr_updates.sh`) prints event lines like `poll.sh`; three small Node helpers do the JSON work (session-to-PR mapping, update summarising, inbox delivery); a bash library keeps the ledger in tab-separated files under `state/pr_updates/`. `windows/poll.ps1` runs the watcher before `poll.sh` and turns its events into toasts.

**Tech Stack:** bash (Git Bash), Node.js (no packages), `gh`, Claude Code CLI 2.1.312 (`claude agents --json --all`, `claude --bg --resume`, the per-session inbox pipe), Windows PowerShell 5.1.

**Spec:** `docs/superpowers/specs/2026-10-29-pr-update-watcher-design.md`

## Global Constraints

- No `jq`, no npm packages. Node scripts use only built-in modules, like `scripts/*.js` today.
- Every state file is tab-separated text under `state/pr_updates/`, read and written with `awk` and `grep` like `state/attempts.txt`.
- Scripts source `scripts/lib.sh` and use `load_config`, `log`, `winpath` conventions. New settings have defaults; `load_config` must not require them.
- A pass that finds nothing spends no tokens and makes at most one `gh` call per watched repository.
- The message never contains a comment body. Exact copy:
  - update: `There is an update on PR <url>: <summary>. Check it out whether any action is needed and proceed if it is.`
  - merge: `PR <url> was merged. Nothing is left to do on it; clean up its worktree and branch if you still have them.`
  - close: `PR <url> was closed without merging. Nothing is left to do on it; clean up its worktree and branch if you still have them.`
- Logins compare case-insensitively (GitHub logins are).
- Unreadable session registry, job state or transcript lines are skipped with a `log` line, never a crash.
- Comments and reviews from `PR_UPDATE_IGNORE_LOGINS` (default `MY_LOGINS` plus `dependabot[bot]`) are not updates.
- Event lines (one per line on stdout, nothing when nothing happened):
  - `NOTIFIED <owner/repo>#<n> <inbox|resume> <session short id> <summary>`
  - `NOT_DELIVERED <owner/repo>#<n> <session short id> <why>`
  - `WATCH_GAVE_UP <owner/repo>#<n> <session short id>`
  - `CAPPED_UPDATES <owner/repo>#<n> <count>`
  - `WATCH_FAILED <why>`
  - `DRY_RUN <what it would do>`

## Review Focus

1. A transcript line that is not complete JSON (the session is writing it right now): `session_prs.js` skips the line and still reports the session. Test in Task 3.
2. A `pr-link` for a repository `gh` cannot read: the pass logs it, skips the PR, continues with the others. Test in Task 6.
3. A PR whose `updatedAt` moved but whose new items are all from ignored logins: `seen.tsv` advances, nothing is sent, no event. Test in Task 6.
4. A message containing quotes or a newline passed to `claude --bg --resume`: it arrives intact (passed as one argv element, never through `eval` or a here-string). Test in Task 6 with the stub `claude`.
5. A registry entry whose pid is dead or whose pipe is gone: `send_to_session.js` exits 1 with a reason, the pass records `NOT_DELIVERED` and keeps the update pending for one retry. Test in Task 4 and Task 6.

---

### Task 0: Spike the two delivery mechanisms (throwaway)

**Files:**
- Create (throwaway, outside the repo): `$CLAUDE_JOB_DIR/tmp/spike/send.js`
- Modify: `docs/superpowers/specs/2026-10-29-pr-update-watcher-design.md` (append a "Spike findings" section)

**Interfaces:**
- Produces: facts for Task 4 and Task 6: whether the inbox frame `{"type":"user","message":{"role":"user","content":"..."}}` after the auth line is delivered to an idle session as a turn and how it is labelled; whether `claude --bg --resume <session id> "<message>"` on a stopped background session keeps the id and runs the message as its first turn; what each cost.

- [ ] **Step 1: Start a throwaway background session**

Run: `claude --bg --name watcher-spike --model haiku "You are a test target. Whenever a message arrives, reply with the single line RECEIVED: followed by the message text, then stop."`
Expected: prints a short id; `claude agents --json` lists `watcher-spike` with a pid.

- [ ] **Step 2: Write `send.js` from the binary's recipe**

Reads `~/.claude/sessions/<pid>.json` and `~/.claude/sessions/<pid>.*.key`, connects to `messagingSocketPath` with `net.connect`, writes `{"type":"auth","token":<peerToken>}\n` then `{"type":"user","message":{"role":"user","content":"spike one"}}\n`, ends.

- [ ] **Step 3: Send and observe**

Run: `node send.js <pid>` then `claude logs watcher-spike`
Expected: the log shows `RECEIVED: spike one`. Note how the incoming message is labelled in the session (peer message, plain user turn, or held for approval).

- [ ] **Step 4: Stop and resume with a message**

Run: `claude stop watcher-spike`, confirm no pid in `claude agents --json --all`, then `claude --bg --resume <full session id> "spike two"`, then `claude logs watcher-spike`
Expected: the same short id (no `note:` line about a copy); log shows `RECEIVED: spike two`.

- [ ] **Step 5: Record findings in the spec**

Append "## Spike findings" with: inbox frame delivered yes/no and its label; resume keeps id yes/no; whether a `note:` copy appeared; anything that contradicts the "How a message is delivered" section. If the inbox frame is not delivered, Task 4 switches to `claude -p --resume <id> "<message>"` run in the background; if `--bg --resume` makes a copy, Task 6 records delivery as `resume-copy` and the plan is updated before Task 6.

- [ ] **Step 6: Clean up and commit**

Run: `claude rm watcher-spike`
```bash
git add docs/superpowers/specs/2026-10-29-pr-update-watcher-design.md
git commit -m "docs: spike findings for session delivery"
```

---

### Task 1: Settings with defaults

**Files:**
- Modify: `config.env` (append a block after `REVIEW_DRAFTS`)
- Modify: `scripts/lib.sh:24-41` (`load_config`)
- Test: `tests/config_defaults.sh`

**Interfaces:**
- Produces: after `load_config`, these variables are set: `PR_UPDATE_ENABLED` (`true`), `PR_UPDATE_IGNORE_LOGINS` (`"$MY_LOGINS dependabot[bot]"`), `PR_UPDATE_MAX_PER_PR_PER_DAY` (`6`), `PR_UPDATE_MAX_RESUMES_PER_PASS` (`2`), `PR_UPDATE_RESUME_RETIRED` (`true`); and the path `PR_UPDATES_DIR="$STATE_DIR/pr_updates"`, created by `load_config`.

- [ ] **Step 1: Write the failing test**

`tests/config_defaults.sh`: copies `config.env` to a temp file with every `PR_UPDATE_*` line removed, sets `AGENT_CODEREVIEW_CONFIG` and a temp `AGENT_CODEREVIEW_STATE`, sources `lib.sh`, calls `load_config`, and checks with the `check` helper style of `tests/classify.sh`:

```
PR_UPDATE_ENABLED = true
PR_UPDATE_IGNORE_LOGINS = "errmakov-fuse errmakov dependabot[bot]"
PR_UPDATE_MAX_PER_PR_PER_DAY = 6
PR_UPDATE_MAX_RESUMES_PER_PASS = 2
PR_UPDATE_RESUME_RETIRED = true
-d "$PR_UPDATES_DIR"
```
Second check: with `PR_UPDATE_MAX_PER_PR_PER_DAY=abc` in the config, `load_config` returns 1 and prints `PR_UPDATE_MAX_PER_PR_PER_DAY must be a number`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/config_defaults.sh`
Expected: FAIL on every line (variables empty, directory missing).

- [ ] **Step 3: Add the settings block to `config.env` and defaults to `load_config`**

`config.env` block, commented like its neighbours, with the five settings at their defaults (`PR_UPDATE_IGNORE_LOGINS=""` meaning "MY_LOGINS plus dependabot[bot]"). In `load_config`: `: "${PR_UPDATE_ENABLED:=true}"` style defaults, the computed ignore list when empty, a digits check for the two numbers, `PR_UPDATES_DIR` added to the `mkdir -p`.

- [ ] **Step 4: Run the test and the existing one**

Run: `bash tests/config_defaults.sh && bash tests/classify.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add config.env scripts/lib.sh tests/config_defaults.sh
git commit -m "feat: settings for the PR update watcher"
```

---

### Task 2: Summarise a PR's new comments and reviews

**Files:**
- Create: `scripts/pr_updates.js`
- Create: `tests/fixtures/pr_updates/*.json`
- Test: `tests/pr_updates.sh`

**Interfaces:**
- Produces: `node scripts/pr_updates.js` reads stdin `{"comments":[...],"reviewComments":[...],"reviews":[...]}` (the raw arrays of `gh api repos/R/issues/N/comments`, `repos/R/pulls/N/comments`, `repos/R/pulls/N/reviews`); env `SINCE` (ISO time, items at or before it are dropped; empty means keep all) and `IGNORE` (space-separated logins). Prints two lines: the newest `created_at`/`submitted_at` among kept items or `-`; the summary phrase or an empty line.
- Summary grammar: parts in this order, only those with a count: approvals (`an approval`, `2 approvals`), change requests (`a review requesting changes`, `2 reviews requesting changes`), comments (`1 comment`, `3 comments`), where comments = issue comments + review comments + `COMMENTED` reviews with a non-empty body; parts joined with `, ` and a final ` and `; then ` from ` and the distinct logins in order of first appearance joined with `, ` and ` and `. `DISMISSED` and `PENDING` reviews are ignored.

- [ ] **Step 1: Write the fixtures and the failing test**

Fixtures: `review_and_comments.json` (one `CHANGES_REQUESTED` review by `samrent-infuse` submitted `2026-10-29T17:40:00Z`, two review comments by `samrent-infuse` created `17:40:10` and `17:41:00`, one issue comment by `errmakov-fuse` created `17:50:00`), `own_only.json` (one comment by `Errmakov-Fuse`), `approval_two_people.json`, `empty_commented_review.json` (a `COMMENTED` review with `"body": ""` wrapping one review comment).

`tests/pr_updates.sh` checks, with `IGNORE="errmakov-fuse errmakov dependabot[bot]"`:

| fixture | SINCE | expected line 1 | expected line 2 |
|---|---|---|---|
| review_and_comments | empty | `2026-10-29T17:41:00Z` (the own comment at 17:50 is ignored) | `a review requesting changes and 2 comments from samrent-infuse` |
| review_and_comments | `2026-10-29T17:40:05Z` | `2026-10-29T17:41:00Z` | `2 comments from samrent-infuse` |
| own_only | empty | `-` | (empty) |
| approval_two_people | empty | newest | `an approval and 1 comment from samrent-infuse and romanvasilenko-infuse` |
| empty_commented_review | empty | newest | `1 comment from samrent-infuse` |

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/pr_updates.sh`
Expected: FAIL, `Cannot find module`.

- [ ] **Step 3: Implement `scripts/pr_updates.js`**

Header comment in the style of `pr_facts.js`. Functions: `keep(items, timeField, since, ignore)`, `countKinds(reviews, comments)`, `phrase(counts, logins)`. Case-insensitive login comparison.

- [ ] **Step 4: Run the test**

Run: `bash tests/pr_updates.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/pr_updates.js tests/pr_updates.sh tests/fixtures/pr_updates
git commit -m "feat: summarise new comments and reviews on a PR"
```

---

### Task 3: Map sessions to the PRs they own

**Files:**
- Create: `scripts/session_prs.js`
- Create: `tests/fixtures/sessions/` (a fake `CLAUDE_HOME`: `jobs/<id>/state.json`, `projects/<slug>/<sid>.jsonl`, and `agents.json`)
- Test: `tests/session_prs.sh`

**Interfaces:**
- Produces: `node scripts/session_prs.js` reads stdin: the JSON array printed by `claude agents --json --all`. Env: `CLAUDE_HOME` (default `$HOME/.claude`), `STATE_DIR` (where `scan.tsv` lives). Prints tab-separated lines:
  - `SESSION\t<short id>\t<session id>\t<live|retired>\t<pid or ->\t<startedAt ms>\t<cwd>\t<name>` for every session that is live (has `pid`) or retired (`kind` is `background`, no `pid`, `jobs/<id>/state.json` exists). Sessions that are neither are not printed.
  - `PR\t<owner/repo>\t<number>\t<session id>\t<created|mentioned>` for every PR link found in transcript bytes not scanned before.
- Transcript path: `linkScanPath` from `jobs/<id>/state.json` when present, else `<CLAUDE_HOME>/projects/<slug>/<sessionId>.jsonl` where slug is the cwd with every character outside `[A-Za-z0-9]` replaced by `-`.
- `created`: a line whose JSON has `type === "pr-link"`, from `prRepository` and `prNumber`. `mentioned`: a line with `type === "user"` whose `message.content` is a string (not an array), for each `github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)` match in it.
- `scan.tsv` rows: `<session id>\t<bytes scanned>`; scanning starts at the recorded offset and records the new file size. A file shorter than its offset is rescanned from 0.

- [ ] **Step 1: Write the fixtures and the failing test**

Fixture `agents.json`: four sessions: `aaaa1111` live (pid 100, cwd `C:\w\repo\.claude\worktrees\HUB-1_x`), `bbbb2222` retired (no pid, job state present with `linkScanPath` pointing to its fixture transcript), `cccc3333` interactive and ended (no pid, no job state), `dddd4444` live but its transcript missing. Transcripts: `aaaa`'s has a `pr-link` for `Org/repo#10`, a user turn with `https://github.com/Org/repo/pull/11` in a string content, a tool_result turn mentioning `pull/12` (must not count), and a last line that is truncated JSON. `bbbb`'s has a `pr-link` for `Org/other#5`.

`tests/session_prs.sh` copies the fixture tree to a temp dir (so `scan.tsv` is fresh), runs the script with `CLAUDE_HOME` and `STATE_DIR` pointing there, and checks:

```
SESSION lines: aaaa1111 live 100, bbbb2222 retired -, dddd4444 live; no cccc3333
PR lines (sorted): Org/other 5 <bbbb sid> created; Org/repo 10 <aaaa sid> created; Org/repo 11 <aaaa sid> mentioned
no PR line for 12
```
Second run on the same temp dir: the same SESSION lines, no PR lines (nothing new). Third: append a `pr-link` for `Org/repo#13` to `aaaa`'s transcript; run; exactly one PR line, for 13.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/session_prs.sh`
Expected: FAIL, `Cannot find module`.

- [ ] **Step 3: Implement `scripts/session_prs.js`**

Functions: `classify(session, claudeHome)` returning `live`, `retired` or `null`; `transcriptPath(session, claudeHome)`; `scanTranscript(path, offset)` returning `{rows, bytes}` reading only from `offset` with `fs.createReadStream({start})` and splitting on `\n`, `try`/`catch` around each `JSON.parse` (a bad line is skipped; the final line without a newline is not counted into `bytes`, so it is read again next time); `readScan`/`writeScan` for `scan.tsv`.

- [ ] **Step 4: Run the test**

Run: `bash tests/session_prs.sh`
Expected: all `ok`.

- [ ] **Step 5: Check against the real machine, read-only**

Run: `claude agents --json --all | STATE_DIR=$(mktemp -d) node scripts/session_prs.js | head -40`
Expected: a SESSION line per listed session with a pid or job state, and PR lines matching the `children` lists in `~/.claude/jobs/*/state.json` (for example `229ee3ce` owns `InfusemediaTeam/inkhub-skeleton 1392 created`).

- [ ] **Step 6: Commit**

```bash
git add scripts/session_prs.js tests/session_prs.sh tests/fixtures/sessions
git commit -m "feat: map Claude Code sessions to the PRs they created or were handed"
```

---

### Task 4: Deliver a message into a live session's inbox

**Files:**
- Create: `scripts/send_to_session.js`
- Test: `tests/send_to_session.sh` (uses a Node one-liner as a fake inbox server)

**Interfaces:**
- Produces: `node scripts/send_to_session.js <pid> <session id>` reads the message from stdin. Env `CLAUDE_HOME`. Reads `<CLAUDE_HOME>/sessions/<pid>.json` (must contain `sessionId === <session id>`, else exit 1 `registry entry is for another session`) and the matching `<pid>.<64 hex>.key`. Connects to `messagingSocketPath`; writes `{"type":"auth","token":<peerToken>}` + `\n`, then `{"type":"user","message":{"role":"user","content":<message>}}` + `\n`; ends; exit 0 when the socket closed without error. Exit 1 with one line on stderr for: missing json or key, connect error (`ENOENT`, `ECONNREFUSED`), timeout after 10 seconds. If Task 0 found the frame is not delivered, this script instead runs `claude -p --resume <session id> <message>` detached and exits 0 once it started.

- [ ] **Step 1: Write the failing test**

`tests/send_to_session.sh`: builds a temp `CLAUDE_HOME/sessions/` with `4242.json` (`sessionId` `s-1`, `messagingSocketPath` `\\.\pipe\LOCAL\cc-msg-test<random>` on Windows or a temp socket path elsewhere) and `4242.<64 zeros>.key` (`peerToken` `0123456789abcdef0123456789abcdef`). Starts a Node fake server on that path that writes every received line to `received.txt` and closes. Checks:

```
echo "hello there" | node scripts/send_to_session.js 4242 s-1   -> exit 0
received.txt line 1 = {"type":"auth","token":"0123456789abcdef0123456789abcdef"}
received.txt line 2 = {"type":"user","message":{"role":"user","content":"hello there\n"}}  (content is stdin verbatim)
node scripts/send_to_session.js 4242 s-other   -> exit 1, stderr "registry entry is for another session"
server stopped; send again                      -> exit 1, stderr contains ENOENT or ECONNREFUSED
node scripts/send_to_session.js 9999 s-1        -> exit 1, stderr "no registry entry for pid 9999"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/send_to_session.sh`
Expected: FAIL, `Cannot find module`.

- [ ] **Step 3: Implement `scripts/send_to_session.js`**

Functions: `readRegistry(home, pid)` returning `{json, key}`; `send(socketPath, token, content)` returning a Promise. Content is stdin as read, no trimming.

- [ ] **Step 4: Run the test**

Run: `bash tests/send_to_session.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/send_to_session.js tests/send_to_session.sh
git commit -m "feat: post a message into a live Claude Code session's inbox"
```

---

### Task 5: The ledger and the lock

**Files:**
- Create: `scripts/watch_lib.sh`
- Test: `tests/watch_ledger.sh`

**Interfaces:**
- Consumes: `PR_UPDATES_DIR`, `PR_UPDATE_MAX_PER_PR_PER_DAY` from Task 1.
- Produces (all in `scripts/watch_lib.sh`, sourced after `lib.sh`; every file tab-separated):
  - `watch_lock` (mkdir `$PR_UPDATES_DIR/lock` with a `pid` file; a lock whose pid is dead is taken over; returns 1 when a live pass holds it), `watch_unlock`.
  - `sessions_save` reads SESSION lines on stdin into `sessions.tsv` (replacing it); `session_field <session id> <short|status|pid|started|cwd|name>` prints one field.
  - `watch_add <repo> <n> <session id> <source>` appends to `watch.tsv` unless the same three keys exist; `watch_drop_gone` removes rows whose session id is not in `sessions.tsv`; `watch_drop_pr <repo> <n>`; `watch_prs` prints distinct `<repo>\t<n>`.
  - `watch_owner <repo> <n>` prints the session id chosen by: `created` before `mentioned`, then `live` before `retired`, then larger `started`.
  - `seen_get <repo> <n>` prints `<updatedAt>\t<newest>` or nothing; `seen_set <repo> <n> <updatedAt> <newest>` replaces the row.
  - `sent_record <repo> <n> <session id> <delivery> <result> <summary...>` appends `<now>\t...` to `sent.log`; `sent_last_day <repo> <n>` prints the number of `sent.log` rows for that PR with result `ok` in the last 86400 seconds.
  - `pending_set <repo> <n> <session id> <attempts> <summary...>` replaces the row in `pending.tsv`; `pending_get <repo> <n>` prints `<session id>\t<attempts>\t<summary>`; `pending_drop <repo> <n>`.
  - `closed_has <repo> <n>`; `closed_add <repo> <n>`.

- [ ] **Step 1: Write the failing test**

`tests/watch_ledger.sh`: temp `AGENT_CODEREVIEW_STATE`, sources `lib.sh` and `watch_lib.sh`, `load_config`. Checks:

```
watch_lock twice in the same shell: second returns 1; after writing a dead pid (99999) into lock/pid, watch_lock returns 0
sessions_save with two SESSION lines (A live started 200, B retired started 300); session_field B status = retired
watch_add Org/r 1 A created; watch_add Org/r 1 A created (dup); watch_add Org/r 1 B created; watch_add Org/r 2 B mentioned
watch.tsv has 3 rows; watch_prs prints "Org/r\t1" and "Org/r\t2"
watch_owner Org/r 1 = A (both created, A is live)
watch_add Org/r 3 B created; watch_add Org/r 3 A mentioned; watch_owner Org/r 3 = B (created wins over live)
sessions_save with only A; watch_drop_gone; watch_prs prints only "Org/r\t1"
seen_get Org/r 1 empty; seen_set Org/r 1 t1 n1; seen_set Org/r 1 t2 n2; seen_get = "t2\tn2"; seen.tsv has one row
sent_record Org/r 1 A inbox ok "2 comments from x" twice, then once with result failed; sent_last_day Org/r 1 = 2
a sent.log row dated 2 days ago is not counted
pending_set Org/r 1 A 1 "summary words"; pending_get = "A\t1\tsummary words"; pending_set again with 2; one row; pending_drop; pending_get empty
closed_has Org/r 1 false; closed_add; closed_has true
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/watch_ledger.sh`
Expected: FAIL, `command not found`.

- [ ] **Step 3: Implement `scripts/watch_lib.sh`**

Header comment naming each file and its columns (as in the spec's ledger table, plus `sessions.tsv` and `scan.tsv`). Rewrite-in-place via `.tmp` and `mv`, like `count_attempt` in `lib.sh`. Timestamps as epoch seconds in `sent.log`'s first column, ISO in the others.

- [ ] **Step 4: Run the test**

Run: `bash tests/watch_ledger.sh`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add scripts/watch_lib.sh tests/watch_ledger.sh
git commit -m "feat: ledger and lock for the PR update watcher"
```

---

### Task 6: The pass

**Files:**
- Create: `scripts/watch_pr_updates.sh`
- Create: `tests/stubs/gh`, `tests/stubs/claude` (bash stubs that answer from `$STUB_DIR` files and record their argv to `$STUB_DIR/calls.log`)
- Test: `tests/watch_pass.sh`

**Interfaces:**
- Consumes: Tasks 1 to 5 as specified in their Interfaces blocks.
- Produces: `bash scripts/watch_pr_updates.sh [--dry-run] [--backfill]`, printing the event lines of Global Constraints and exiting 0; `WATCH_FAILED` and exit 1 when `claude agents --json --all` fails. Does nothing and prints nothing when `PR_UPDATE_ENABLED` is not on.
- Pass steps, each its own function of at most 50 lines:
  1. `list_sessions`: `claude agents --json --all | node session_prs.js`; SESSION lines to `sessions_save`, PR lines to `watch_add`; then `watch_drop_gone`.
  2. `check_repo <repo>`: one `gh pr list --repo <repo> --state open --limit 100 --json number,updatedAt`; for each watched PR of that repository: present and `updatedAt` newer than `seen_get` → `fetch_updates`; absent → `settle_closed`.
  3. `fetch_updates <repo> <n> <updatedAt>`: three `gh api` calls (`issues/<n>/comments?since=<newest>&per_page=100`, `pulls/<n>/comments?since=<newest>&per_page=100`, `pulls/<n>/reviews?per_page=100`) into one JSON object for `pr_updates.js` with `SINCE=<newest>` and `IGNORE="$PR_UPDATE_IGNORE_LOGINS"`; empty summary → `seen_set` only; else `deliver`.
  4. `deliver <repo> <n> <summary> <kind>`: `sent_last_day` at or above the cap → `CAPPED_UPDATES`; owner from `watch_owner`; live → `send_to_session.js`; retired and `PR_UPDATE_RESUME_RETIRED` on and resumes this pass below `PR_UPDATE_MAX_RESUMES_PER_PASS` and this session not yet resumed in this pass → `cd <cwd> && claude --bg --resume <session id> "<message>"` (the message as one argument), resumes counter +1, session id noted as resumed; retired otherwise (cap reached, switch off, or already resumed this pass, since a second `--bg --resume` on a now-running session would start a copy) → stays pending, no event, delivered next pass when the session is live; success → `sent_record ... ok`, `seen_set`, `pending_drop`, `NOTIFIED`; failure → `pending_set` with attempts +1 and `NOT_DELIVERED`, or `WATCH_GAVE_UP` and `pending_drop` when attempts reach 2.
  5. `settle_closed <repo> <n>`: `gh pr view <n> --repo <repo> --json state,mergedBy`; `OPEN` → nothing (beyond the 100-PR window); `MERGED` → notice unless `mergedBy.login` is in `MY_LOGINS`; `CLOSED` → closer from `gh api repos/<repo>/issues/<n>/timeline?per_page=100` (last `closed` event's `actor.login`), notice unless in `MY_LOGINS`; notice goes through `send_to_session.js` only when the owner is live, never a resume; then `closed_add`, `watch_drop_pr`, `pending_drop`.
  6. Pending rows are retried at the start of the pass before new updates, through `deliver`.
- `--dry-run`: every `gh` read runs, nothing is written to the ledger or sent; `session_prs.js` gets a temporary `STATE_DIR` so `scan.tsv` is untouched; each would-be action prints `DRY_RUN ...`.
- `--backfill`: for every watched open PR with no `seen.tsv` row, `SINCE` is empty instead of now, so waiting reviews count as new; otherwise a normal pass.
- First sight of a PR without `--backfill`: `seen_set <repo> <n> <updatedAt> <now>` and no fetch.

- [ ] **Step 1: Write the stubs and the failing test**

`tests/stubs/gh`: appends `gh $*` to `$STUB_DIR/calls.log`; answers `pr list` from `$STUB_DIR/pr_list_<owner>_<repo>.json`, `api repos/<r>/issues/<n>/comments` from `$STUB_DIR/comments_<n>.json`, `api repos/<r>/pulls/<n>/comments` from `review_comments_<n>.json`, `api .../reviews` from `reviews_<n>.json`, `pr view <n>` from `pr_view_<n>.json`, `.../timeline` from `timeline_<n>.json`; a missing file means `[]`; a file named `fail_<owner>_<repo>` makes any call on that repository print `gh: Could not resolve to a Repository` on stderr and exit 1. `tests/stubs/claude`: `agents --json --all` prints `$STUB_DIR/agents.json`; `--bg --resume <sid> <msg>` appends `resume\t<sid>\t<msg>` to `calls.log` and prints `abcd1234`.

`tests/watch_pass.sh`: temp state dir, `PATH="$PWD/tests/stubs:$PATH"`, `CLAUDE_HOME` pointing at the Task 3 fixture tree (so `aaaa1111` is live with pid 100 and `bbbb2222` retired), a fake inbox server for pid 100 as in Task 4, config with `MY_LOGINS="errmakov-fuse errmakov"`. Scenarios, each a fresh state dir unless noted:

```
first pass: Org/repo#10 and #11 open with updatedAt t1 → no events; seen.tsv has rows for 10 and 11 with t1; calls.log has exactly one "gh pr list" per repository and no "gh api"
second pass, #10 updatedAt t2, comments_10.json has a samrent-infuse comment → NOTIFIED Org/repo#10 inbox aaaa1111 1 comment from samrent-infuse; the fake inbox received a user frame whose content starts with "There is an update on PR https://github.com/Org/repo/pull/10: 1 comment from samrent-infuse."; sent.log has one ok row
same state, third pass, nothing changed → no events, no "gh api" calls
#10 updatedAt t3, only an errmakov-fuse comment → no events; seen row for 10 has t3 (Review Focus 3)
Org/other#5 (owner bbbb2222, retired) updatedAt moves with a review → calls.log has exactly one line "resume\t<bbbb sid>\tThere is an update on PR https://github.com/Org/other/pull/5: a review requesting changes from samrent-infuse. Check it out whether any action is needed and proceed if it is." (the whole message in one argv element, Review Focus 4); event NOTIFIED Org/other#5 resume bbbb2222 a review requesting changes from samrent-infuse
bbbb2222 also owns Org/other#6, both updated in one pass → one resume line in calls.log (for #5), pending.tsv has a row for Org/other 6, no event for #6
PR_UPDATE_RESUME_RETIRED=false, same → no resume call, no event, pending.tsv has a row for Org/other 5
PR_UPDATE_MAX_RESUMES_PER_PASS=0, same → same as above
cap: sent.log pre-filled with 6 ok rows for Org/repo#10 today, update arrives → CAPPED_UPDATES Org/repo#10 6, nothing sent, seen advances
inbox server stopped, update on #10 → NOT_DELIVERED Org/repo#10 aaaa1111 ...; pending.tsv row attempts 1; next pass with the server still down → WATCH_GAVE_UP Org/repo#10 aaaa1111, pending row gone (Review Focus 5)
#11 missing from pr_list, pr_view_11.json state MERGED mergedBy samrent-infuse → inbox receives "PR https://github.com/Org/repo/pull/11 was merged. ..."; closed.txt has Org/repo 11; watch.tsv has no row for 11
#10 missing, pr_view_10 MERGED mergedBy errmakov-fuse → no message, closed.txt has it
Org/other#5 missing, pr_view_5 MERGED (owner retired) → no resume call, closed.txt has it
fail_Org_other present → events contain nothing for Org/other; poll.log has a line containing "Org/other"; Org/repo is still processed (Review Focus 2)
--dry-run with #10 updated → output has a DRY_RUN line naming Org/repo#10 and aaaa1111; sent.log absent; seen.tsv unchanged
--backfill on a fresh state with reviews_10.json holding an old samrent-infuse review → NOTIFIED for #10
stub claude made to exit 1 on "agents" → WATCH_FAILED ..., exit 1
PR_UPDATE_ENABLED=false → no output, exit 0, no calls.log
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/watch_pass.sh`
Expected: FAIL, `No such file or directory: scripts/watch_pr_updates.sh`.

- [ ] **Step 3: Implement `scripts/watch_pr_updates.sh`**

Header comment in the style of `poll.sh` listing the event lines and flags. The three message templates as constants at the top. `winpath` for paths handed to Node. Resumes run with `cd "$cwd"` in a subshell; when `cwd` no longer exists, fall back to `$ROOT` and log it.

- [ ] **Step 4: Run all tests**

Run: `for t in tests/*.sh; do bash "$t" || echo "FAILED $t"; done`
Expected: every check `ok`, no `FAILED`.

- [ ] **Step 5: Dry-run against the real machine**

Run: `bash scripts/watch_pr_updates.sh --dry-run`
Expected: exit 0; `state/pr_updates/watch.tsv` is not created (dry run); output is empty or `DRY_RUN` lines only; `state/poll.log` gained no error lines. Then `AGENT_CODEREVIEW_STATE=$(mktemp -d) bash scripts/watch_pr_updates.sh` once for real into a scratch state dir: exit 0, no events (first sight enrols silently), `watch.tsv` lists the sessions' PRs.

- [ ] **Step 6: Commit**

```bash
git add scripts/watch_pr_updates.sh tests/watch_pass.sh tests/stubs
git commit -m "feat: tell a session when its PR gets a comment or review"
```

---

### Task 7: Run it from the scheduled pass with toasts

**Files:**
- Modify: `windows/poll.ps1:69-100` (the Format-Key helper and the event switch)

**Interfaces:**
- Consumes: event lines from Task 6.
- Produces: `poll.ps1` runs `scripts/watch_pr_updates.sh` before `scripts/poll.sh` (so a pass waiting on an hour-long review never delays the watcher), appends its events to `events.log`, and toasts:
  - `NOTIFIED <repo>#<n> inbox <id> <summary>` → title `PR #<n>: update`, text `<summary>. Told session <id>.`
  - `NOTIFIED <repo>#<n> resume <id> <summary>` → title `PR #<n>: update`, text `<summary>. Resumed session <id>.`
  - `NOT_DELIVERED` → title `PR #<n>: session <id> not reached`, text `<why>. Tried again next pass.`
  - `WATCH_GAVE_UP` → title `PR #<n>: carry the message by hand`, text `Session <id> could not be reached twice.`
  - `CAPPED_UPDATES` → title `PR #<n>: update not forwarded`, text `<count> messages today already (PR_UPDATE_MAX_PER_PR_PER_DAY).`
  - `WATCH_FAILED` → title `PR watcher cannot list sessions`, text `See state\poll.log.`
  - `DRY_RUN` → log only.

- [ ] **Step 1: Add a `Format-PrKey` helper and the new switch cases; run the watcher first**

`Format-PrKey "Org/repo#10"` returns `#10`. The watcher is run with the same `& $bash $script 2>$null | ForEach-Object` pattern, in its own block before `poll.sh`.

- [ ] **Step 2: Verify by hand**

Run: `powershell -ExecutionPolicy Bypass -File windows\poll.ps1 -NoToast`
Expected: exit 0; `state\events.log` gains a timestamped line for each event printed, with the watcher's lines (if any) before the reviewer's; `state\poll.log` gains no error line. `Show-Toast` itself is unchanged and already proven by the reviewer's events, so no toast check is needed here.

- [ ] **Step 3: Commit**

```bash
git add windows/poll.ps1
git commit -m "feat: run the PR update watcher in the scheduled pass with toasts"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md` (the "What is in here" table, the cost controls table, a new section "Updates on your sessions' PRs" after "When a PR is reviewed again", the "Try it by hand" block, the "Limits" list)
- Modify: `AGENT.md` (a section "PR updates to sessions" after "Doing things by hand", rows in the "Where to look" table for `state/pr_updates/`)

**Interfaces:**
- Consumes: the final behaviour of Tasks 1 to 7.

- [ ] **Step 1: README**

Rows for `scripts/watch_pr_updates.sh`, `scripts/watch_lib.sh`, `scripts/session_prs.js`, `scripts/pr_updates.js`, `scripts/send_to_session.js`, `tests/watch_pass.sh`. Cost table rows for the five settings. The new section in the README's voice: which sessions and PRs count (the spec's table in prose), what counts as an update, the two delivery mechanisms, the resume cost warning, `--dry-run` and `--backfill`, where the ledger is. Limits: Claude Code internal interfaces may change; only background sessions are resumed.

- [ ] **Step 2: AGENT.md**

Table rows: `state/pr_updates/watch.tsv`, `sent.log`, `pending.tsv`, `closed.txt`, `sessions.tsv`, `scan.tsv` with one-line meanings. Section: how to run the watcher by hand, how to re-enrol a PR (delete its `seen.tsv` row and run `--backfill`), and the trap "a resumed session keeps running until the daemon retires it".

- [ ] **Step 3: Read both files once as a newcomer and fix what does not stand alone**

- [ ] **Step 4: Commit**

```bash
git add README.md AGENT.md
git commit -m "docs: the PR update watcher"
```
