# PR update watcher: design

Date: 2026-10-29. Status: draft for the owner's sign-off. Nothing here is built yet.

## Intent

A second service in this repository, next to the PR reviewer. It watches the pull requests that the owner's Claude Code sessions created or were handed, and when somebody comments on one of them, it tells the session that owns the PR so the session can read the comment and act on it, without the owner carrying the message by hand.

Why: the owner runs many Claude Code sessions in parallel (the agent view lists eighteen from the last two weeks, six alive right now). Each opens one or more PRs. Reviewers answer hours later, by which time the session has gone quiet, and today the owner has to notice the comment, find the right session, reopen it and paste the link. The watcher closes that loop.

## Goals

- Every comment or review a teammate leaves on a PR owned by a session reaches that session as a message within one polling interval.
- The session that gets the message is the one that made the PR, so it has the context to act.
- A retired session (its process gone after an hour idle) is resumed automatically so the PR gets handled with nobody watching. This is the owner's decision.
- Nothing is sent twice. Everything sent is on record.
- A pass that finds nothing costs no tokens, like the reviewer's pass.

## Non-goals

- Reacting to CI results, pushes, labels or assignments. Comments and reviews only, plus one closing notice when a PR is merged or closed.
- Watching PRs no session is connected to.
- Deciding what the session should do. The message says there is an update and asks the session to check and proceed; the session decides.
- A new scheduler, daemon or UI. The watcher is one more script in the existing five-minute pass.

## Anti-goals

- Spending tokens in a loop: a session that replies to a comment must not be woken by its own reply, and two sessions must not be woken for one comment.
- Injecting a teammate's comment text into a session that runs with permissions bypassed. The message carries the link, the commenter and the kind of update, never the comment body. The session reads the comment itself with `gh`.
- A watcher that breaks the reviewer. It runs after the reviewer's pass and shares only `lib.sh` and `config.env`; its own state lives under `state/pr_updates/`.

## Constraints

- Windows 11, Git Bash, Node.js, `gh` logged in as `REVIEW_AS`, Claude Code 2.1.312. No `jq`.
- The pass is `windows/poll.ps1`, run by Task Scheduler every `POLL_SECONDS`, which runs `scripts/poll.sh` and turns its event lines into toasts and `state/events.log` lines. The watcher plugs into that: a script that prints event lines, and a few new cases in `poll.ps1`.
- The owner's sessions are background ("fleet") sessions managed by the Claude Code daemon. The daemon retires one after about 60 minutes idle (`daemon.log`: `bg retire <id>: settled, idle 61m`) and respawns it when the owner opens it. A retired session keeps its transcript and job state and is resumable.
- Session facts come from interfaces that Claude Code documents as unstable. The watcher reads them defensively and treats anything it cannot parse as "no sessions" or "no PRs", with a log line, never a crash.

## What is decided

### Which sessions count as active

Owner's wording: the service listens on PRs "mentioned in active sessions". Decided here (my call, the owner asked for the clarification):

| Session | Active? | How it is told |
|---|---|---|
| Live, background or interactive: listed by `claude agents --json` with a pid, idle or busy | yes | message to its inbox; a busy session gets it as its next turn |
| Retired background session: listed by `claude agents --json --all`, no pid, job state in `~/.claude/jobs/<id>/` | yes | resumed with the message as its first turn (owner's decision) |
| Interactive session the owner has closed: transcript, no pid, no job state | no | its PRs are dropped; the owner's sessions are all background sessions today, and resuming a closed terminal session as an unattended background one would be a surprise |
| Deleted with `claude rm`, or no job state and no transcript | no | its PRs are dropped from the watch list |
| A `-p` review run of this repository (`state/runs/`) | no | never watched; these are not the owner's working sessions |

Done-ness does not matter: a session that printed `result:` and whose PR then gets a review is exactly the case the watcher is for.

### Which PRs belong to a session

Claude Code writes a `pr-link` record into a session's transcript when the session creates a PR (`gh pr create`), with the PR number, URL and repository. The job tracker builds the session's PR list from it, and `claude --from-pr` searches it. This is the primary source: precise, and free to read.

Second source (my call): a PR URL that appears in a user turn of the transcript, that is, a PR the owner pasted to the session. Tool output is ignored, since `gh pr list` output mentions dozens of PRs incidentally.

Any repository counts, not only `REPO`; the sessions also open PRs on this repository itself. `gh` must have access to it, or the PR is logged and skipped.

When several sessions name one PR (the owner forks sessions, and forks share history), the message goes to the session that created it. If that session is deleted, it goes to the most recently updated active session that mentions it. One session per PR per update, never more.

### What counts as an update

Comments on the conversation tab, review comments on the diff, and reviews (approve, request changes, comment), from any login not in `MY_LOGINS`. Comments by the owner's logins are ignored, which is also what stops the loop: the session posts replies as `REVIEW_AS`, and those never come back as updates.

Also one final notice when the PR is merged or closed, after which the PR leaves the watch list. My call: the session usually has a worktree and a branch to clean up. The notice is cheap only for a live session, so it goes through the inbox only: a retired session is never resumed for a merge or close, and no notice is sent when the merger or closer is one of `MY_LOGINS` (the owner or the session itself did it and already knows). The PR leaves the watch list either way.

Several updates on one PR in one pass make one message.

### The message

The owner's wording, with the facts the watcher already has:

> There is an update on PR https://github.com/InfusemediaTeam/inkhub-skeleton/pull/1392: a review requesting changes and 2 comments from samrent-infuse. Check it out whether any action is needed and proceed if it is.

For a merge or close: "PR <url> was merged. Nothing is left to do on it; clean up its worktree and branch if you still have them."

No comment bodies, ever (see anti-goals).

### How a message is delivered

Two mechanisms, chosen by the session's state:

1. **Live session: its inbox.** Claude Code documents a per-session inbox for scripts and hooks to post into: on Windows a named pipe, first line `{"type":"auth","token":"<token>"}`, then a user-message frame. The pipe path and token are in `~/.claude/sessions/<pid>.json` and the matching `.key` file. The message frame after the auth line is not in the public docs; the binary's own debug text gives the recipe (`{"type":"user","message":{"role":"user","content":"..."}}`), and the sender is pinned to that. No tokens are spent delivering, either way. **The receiving session may hold the message instead of delivering it** (see the spike findings): a session that bypasses permission prompts holds a peer message that carries no attested permission mode, and the socket has no way to attest one, so the message stays held until the owner delivers it in the session, unless the owner sets `crossSessionInbound` to `"accept"` in their user settings. A held send looks like success to the sender. The watcher therefore always toasts alongside the inbox frame, never changes the owner's settings, and the README tells the owner that `crossSessionInbound: "accept"` makes delivery automatic.
2. **Retired session: resume it.** `claude --bg --resume <session id> "<message>"` restarts the session from its saved conversation under the same id, as the daemon does, with the message as its first turn. This re-reads the whole context (these sessions hold 150K tokens and more) and then does the work the message triggers, on the session's own model. The owner chose this over waiting for the session to be reopened.

`claude -p --resume <session id> "<message>"` is not a fallback for a live session: it refuses one (spike findings). The "retired" case was tested with `claude stop`, not a daemon retirement, and is assumed equivalent.

A delivery that fails prints a `NOT_DELIVERED` event, which `poll.ps1` turns into a toast naming the PR and the session, so the owner can carry the message by hand. For the inbox, `NOT_DELIVERED` fires only when the pipe write itself fails (missing registry entry, connect error, timeout); a held frame gives no signal and counts as delivered `inbox`. The ledger keeps the update as pending and tries once more on the next pass, then gives up with a `GAVE_UP` event.

### Cost guards (my calls, all in `config.env`)

| Setting | Default | Effect |
|---|---|---|
| `PR_UPDATE_IGNORE_LOGINS` | `$MY_LOGINS` plus `dependabot[bot]` | Updates from these logins are not updates. |
| `PR_UPDATE_MAX_PER_PR_PER_DAY` | 6 | After this many messages on one PR in 24 hours, further updates are only toasted. Protects against a comment thread that goes back and forth. |
| `PR_UPDATE_MAX_RESUMES_PER_PASS` | 2 | At most this many retired sessions are resumed in one pass. The rest wait for the next pass. |
| `PR_UPDATE_RESUME_RETIRED` | `true` | `false` turns the retired case into toast plus the message sent to the session's inbox when it is next alive (held there until the owner delivers it, unless `crossSessionInbound` is `accept`). |
| `PR_UPDATE_ENABLED` | `true` | Off switch. |

### The ledger: `state/pr_updates/`

Plain text files, one record per line, read and written with the same `awk` and `grep` idioms as `state/attempts.txt`. No new dependencies.

| File | One line per | Columns |
|---|---|---|
| `watch.tsv` | PR under watch | repo, number, owning session id, source (`created` or `mentioned`), first seen |
| `seen.tsv` | PR under watch | repo, number, PR `updatedAt` last checked, newest comment or review time processed |
| `sent.log` | message sent | time, repo, number, session id, delivery (`inbox`, `resume`, `toast`), kind summary, result |
| `pending.tsv` | update not yet delivered | repo, number, session id, kind summary, attempts |
| `closed.txt` | PR merged or closed and told | repo, number, time |

`watch.tsv` is rebuilt each pass from the sessions (a PR appears when its session does, leaves when the session is deleted or the PR is closed); the other files are append-and-rewrite like the reviewer's state.

**Baseline for a PR seen for the first time** (my call): its `seen.tsv` row starts at the moment it is first seen, so only updates after that count. A PR that is already merged or closed when first seen goes straight to `closed.txt` without a notice. On the first pass after install this means the eighteen known sessions and their PRs are enrolled silently, and no session is resumed for a review that was already waiting. For that backlog there is `watch_pr_updates.sh --backfill`, run by hand: it treats every unanswered review or comment on a watched open PR as new, prints what it would send under `--dry-run`, and sends without it. The caps apply to a backfill like to a pass.

### The pass

`scripts/watch_pr_updates.sh`, run by `poll.ps1` after `poll.sh`, printing event lines:

1. List sessions (`claude agents --json --all`); for each, find its transcript and read its PR links. Update `watch.tsv`.
2. Group watched open PRs by repository; one `gh pr list --repo <r> --state open --json number,updatedAt,...` per repository, filtered to the watched numbers. PRs missing from the list are checked once with `gh pr view` for merged or closed.
3. For each PR whose `updatedAt` moved past `seen.tsv`: fetch comments, review comments and reviews newer than the last processed time; drop ignored logins; summarise.
4. For each PR with a summary: pick the session, pick the mechanism, deliver, record in `sent.log`, advance `seen.tsv`. Print `NOTIFIED <repo>#<n> <session name> <inbox|resume>`.
5. Merged or closed: deliver the closing notice once, record in `closed.txt`, drop from watch.

Events for `poll.ps1`: `NOTIFIED` (toast: "PR #1392: review from samrent-infuse, told HUB-232"), `RESUMED` (toast: "... resumed HUB-232"), `NOT_DELIVERED`, `GAVE_UP`, `WATCH_FAILED` (listing failed). Every event is also appended to `state/events.log`.

A `--dry-run` prints what it would send and sends nothing, like `poll.sh --dry-run`.

### Spike first

Before the real build, one throwaway check, kept out of the product code:

- Send a harmless message into a live session through its inbox and confirm it arrives as a user turn and how it is labelled.
- Resume a retired test session with `claude --bg --resume <id> "<message>"` and confirm: same id, message is the first turn, the session's saved permission mode and model apply, and the agents view shows it. Compare with `claude -p --resume`.
- Note what each cost in tokens, from the session's own usage.

What the spike finds goes into the plan; if (1) or (2) does not behave as described here, this document is updated before anything else is built.

## Left to the builder

- Transcript location for a session without job state (interactive sessions): the project slug under `~/.claude/projects/` is the cwd with every non-alphanumeric character replaced by `-`; verify against the live sessions before relying on it.
- Exact `gh api` endpoints and `since` handling for the three update kinds, and how to fold them into one summary line.
- Where `poll.ps1` runs the watcher relative to waiting for review runs, so a long review does not delay the watcher.
- Tests: the summariser and the session-to-PR mapping against made-up fixtures, like `tests/classify.sh` does for the reviewer's rules.
- README and `AGENT.md` sections, following the existing tables.

## Risks the owner should know

- **Unstable interfaces.** The session registry, job state, `pr-link` record and inbox frame are all documented as internal or not documented at all. A Claude Code update can break any of them silently. The watcher logs `WATCH_FAILED` and toasts when it can no longer read sessions, so the failure is visible, not quiet.
- **Unattended spend.** Each resumed session re-reads its full context and then works, on its own model (opus for most of these sessions), with nobody watching. The per-PR and per-pass caps bound the number of wake-ups, not what a wake-up costs. The reviewer's `MAX_RUN_USD` cannot apply: the session is the owner's, not a lean run.
- **Resumed sessions keep running.** A `--bg --resume` session stays alive until the daemon retires it again, so a burst of comments on several PRs leaves several sessions awake for an hour each. Harmless in tokens (an idle session costs nothing), noticeable in the agents view.
- **Two writers.** If the owner is typing in a session while the watcher posts to its inbox, both turns interleave into one transcript. The docs allow it; it may surprise.

## Spike findings

Run on 2026-10-29 against Claude Code 2.1.312 on this machine, with a throwaway haiku background session `watcher-spike` (short id `c6ac0028`, started in this worktree). The session was removed afterwards.

**1. Inbox frame: reaches the session but is held, not delivered (contradicts "How a message is delivered", point 1).**

- `claude --bg --name watcher-spike --model haiku "<test-target prompt>"` listed `watcher-spike` with a pid. A script following the recipe (connect to `messagingSocketPath`, write the auth line with `peerToken`, then `{"type":"user","message":{"role":"user","content":"spike one"}}`, end) connected and closed without error.
- `claude logs watcher-spike` showed no `RECEIVED: spike one`. Instead the session printed: `Held peer message - from an unidentified session; preview: «spike one» - not delivered to Claude (1 held). The sender did not attest its permission mode and this session bypasses prompts. Review it below, or set "crossSessionInbound" to "accept".` and a dialog "Another Claude session sent a message ... Deliver this message to Claude". The registry entry went to `status: waiting`, `waitingFor: permission prompt`.
- So the label is "peer message, held for approval". Cause, from the session's own on-screen text and the binary's strings (inferred, not tested beyond the one observed hold): Claude Code 2.1.312 has a `crossSessionInbound` setting (`accept`, `hold`, `refuse`). A session that bypasses permission prompts (these background sessions do) holds a peer message whose sender did not attest a permission mode (reason code `no-mode-asserted`, seen on screen as "The sender did not attest its permission mode"); a sender of a different mode class would be held as `mode-mismatch` (from binary strings only, never observed). The binary's text says the sender's mode is declared only by the host that injects on local stdin, not on the socket lane.
- One variant of the same mechanism: the user frame with extra `fromMode:"bypass"` and `from` fields was held the same way (still "from an unidentified session"). No way to attest a mode over the socket was found.
- Observed: the message stayed held while the session was idle, and `spike one` was not in the session after the stop and resume. From binary strings, not tested: a held message is released when someone approves it in the session or `crossSessionInbound` is `"accept"`, and expires when the session stops (the delivery after accept, and how it is labelled, is unverified). The setting was not changed in this spike (it lives in the owner's user settings; managed or repo settings can also pin it).
- Consequence for the plan: unless the owner sets `crossSessionInbound` to `accept` in user settings, the inbox frame does not reach a bypass-mode session as a turn. The socket gives the sender no sign that a message was held, so an inbox send cannot report success. See "Task 4 routes" below for what Task 4 does.

**2. `claude --bg --resume <full session id> "spike two"` on a stopped background session: works, keeps the id, no copy.**

- `claude stop watcher-spike` printed `No job matching 'watcher-spike'` while the session was in `waiting` (permission prompt); `claude stop c6ac0028` printed `stopped c6ac0028`. After 6 seconds `claude agents --json --all` showed the entry with no `pid`.
- `claude --bg --resume c6ac0028-711d-416b-ae50-d53ee27a562a "spike two"` printed `note: woke session c6ac0028 with its saved options (--name, --model).` and `backgrounded · c6ac0028 · watcher-spike`. This `note:` is not about a copy. Same short id, same `sessionId`, same name, new pid.
- `claude logs watcher-spike` after 30 seconds: `spike two` appeared as a plain user turn (`❯ spike two`) with the reply `RECEIVED: spike two`. The earlier held `spike one` was never delivered. The turn took about 9 seconds on haiku with a tiny context; the cost for a real 150K-token session was not measured.
- Consequence: Task 6 records delivery as `resume`, not `resume-copy`; no plan change.

**Other observations**

- `claude stop` and `claude rm` by name answered `No job matching` for a session with a pending permission prompt; by short id both worked. Task 4 and Task 6 should address sessions by short id.
- `claude logs` prints raw terminal output with ANSI escapes; strip them before matching text.
- The label of an accepted inbox message was not observed, since none was accepted.

### Live session fallback: claude -p --resume

Second throwaway haiku session `watcher-spike` (short id `fa37c4e5`, full id `fa37c4e5-e095-475d-a449-8db4447d7a93`), idle with pid 7304. From a different directory (the spike scratch folder), with the session running:

- `claude -p --resume fa37c4e5-e095-475d-a449-8db4447d7a93 "spike three"` returned after about 2 seconds with exit code 1, nothing on stdout, and on stderr: `Error: That session is running in the background (fa37c4e5). Run \`claude attach fa37c4e5\` to open it, or \`claude stop fa37c4e5\` first to resume it here. Add --fork-session to branch off a copy instead.`
- No `note:` line. `claude agents --json --all` still showed one row for the session (same id, pid 7304, idle). `claude logs fa37c4e5` after 25 seconds showed no `spike three`: the running session never received the prompt.
- The `--output-format json` repeat was not run, since the first call delivered nothing. `--fork-session` was not tried: it makes a copy, which is not delivery to the owner's session.
- So the documented claim that `-p --resume` posts into a running background session is wrong for 2.1.312. It refuses for a live session. The error text ("`claude stop` first to resume it here") implies it would resume a stopped one; that was not tested (finding 2 tested `--bg --resume` on a stopped session).

Task 4 routes (controller ruling):

1. **Live session:** always the inbox frame AND a toast. The frame becomes a turn automatically only if the owner sets `crossSessionInbound: "accept"` in their user settings; accept-mode delivery was never exercised in the spike and is unverified. Otherwise the frame is held in the session until the owner delivers it, and the toast is how they find out. The watcher does not change settings; the README tells the owner that `"accept"` makes it automatic. That setting is the owner's choice.
2. **Retired session:** `claude --bg --resume <full session id> "<message>"`, recorded as `resume` (finding 2). The spike tested this after `claude stop`, not after a daemon retirement; the two are assumed equivalent.

`claude -p --resume` is not used for live sessions: it refuses them.
