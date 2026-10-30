# agent-codereview

Reviews your teammates' pull requests for you with Claude Code. It requests you as reviewer on their new PRs, reviews each one with a reviewer subagent briefed from the superpowers `requesting-code-review` template, and posts the findings as an approval or a change request. When a PR it asked changes on gets new commits, it reviews it again. It also puts a reviewer on your own PRs when they have none, and tells you when one of your PRs still needs an approval but nobody is asked for one. A second part, the PR update watcher, tells the Claude Code session that opened one of your PRs when a teammate comments on it or reviews it.

## How it runs

A Windows scheduled task runs `windows/poll.ps1` every five minutes. That runs one pass of `scripts/watch_pr_updates.sh` (the PR update watcher, see below) and then one of `scripts/poll.sh`, which lists the open PRs with `gh` and decides what needs doing. A pass that finds nothing costs no tokens.

Each PR that needs a review gets its own run of `scripts/run_review.sh`. It gathers the facts with `gh` and `git` (metadata, a checkout, the earlier review, a patch comparison), then starts a fresh headless Claude run that briefs one reviewer subagent, checks the findings the verdict rests on, posts, and exits. You get a Windows notification when a review starts and when it is posted.

The reviewer uses no long-lived Claude session. That is where the cost was: a session that watched for weeks re-read its whole history, up to 965K tokens, on every wake-up, and a scheduled self-check every 10 minutes cost more than the reviews. A fresh run starts from about 10K tokens of context (`scripts/claude_lean.sh`) and is gone when the review is posted.

## What is in here

| Path | What it is |
|---|---|
| `config.env` | Repository, logins, models, limits. The only file to edit for another repo or team. |
| `AGENT.md` | Notes for a Claude session asked about the reviewer, or to review a PR by hand. |
| `scripts/poll.sh` | One pass over the open PRs: requests reviewers and starts review runs. |
| `scripts/run_review.sh` | Reviews one PR in a fresh headless run and posts the result. `--test` does everything but post. |
| `scripts/classify.jq` | The rules that decide which open PRs need a first review, a re-review, or a reviewer. |
| `scripts/compare_patch.sh` | Tells whether a force-pushed PR still contains what was reviewed, so an unchanged one is approved again cheaply. |
| `scripts/claude_lean.sh` | Runs `claude -p` with a context of about 10K tokens instead of 51K: no global rules, plugins, MCP servers or unused tools. |
| `scripts/measure_context.sh` | Prints that fixed context, to check after a Claude Code update. |
| `scripts/lib.sh`, `*.js` | Shared helpers: config, locks and attempts, prompt filling, result parsing. |
| `prompts/run-review.md`, `prompts/run-rereview.md` | What a run does: steps, verdict rule, review layout. |
| `prompts/reviewer.md` | The reviewer subagent's prompt: the superpowers `requesting-code-review` template (MIT), with working rules that keep a review to about 25 tool calls. |
| `prompts/project-context.md` | What the reviewer must know about the watched repository. Edit it for another repo. |
| `claude/lean-settings.json` | The settings `claude_lean.sh` runs with. |
| `windows/poll.ps1`, `windows/install.ps1` | The scheduled task and its notifications. |
| `scripts/watch_pr_updates.sh` | One pass of the PR update watcher: finds the PRs your sessions own, reads their new comments and reviews, tells the owning session. `--dry-run`, `--backfill`. |
| `scripts/watch_gh.sh`, `scripts/watch_lib.sh` | The watcher's `gh` reads, and its ledger files and lock under `state/pr_updates/`. |
| `scripts/session_prs.js` | Lists your Claude Code sessions and the PRs in their transcripts. |
| `scripts/pr_updates.js` | Turns the comments and reviews of one PR into a one-line summary of what is new. |
| `scripts/send_to_session.js` | Posts a message into a live session's inbox. |
| `tests/classify.sh` | Checks the rules against made-up PRs in `tests/classify_cases.json`. |
| `tests/watch_pass.sh` | Runs whole watcher passes against stub `gh` and `claude` commands (`tests/stubs/`), made-up sessions (`tests/fixtures/`) and a fake inbox (`tests/fake_inbox.js`). Nothing real is touched. |
| `tests/pr_updates.sh`, `session_prs.sh`, `send_to_session.sh`, `watch_ledger.sh`, `config_defaults.sh` | Checks of the watcher's parts. |
| `skills/irl/` | The `irl` skill: shows one concrete case for a statement that is too abstract. |

## Requirements

- Claude Code, logged in. The superpowers plugin is not needed: its reviewer template is copied, with changes, into `prompts/reviewer.md`.
- `gh`, logged in as the account in `REVIEW_AS`, with write access to the watched repository.
- Git for Windows (Git Bash) at `GIT_BASH`, and Node.js. `jq` is not needed.
- A local clone of the watched repository at `LOCAL_CHECKOUT`. Reviews check PRs out into `.claude/worktrees/review-<n>` under it and remove them afterwards.

## Install

1. Clone this repository and edit `config.env`.
2. Register the scheduled task (no administrator rights needed):

   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\install.ps1
   ```

   It runs while you are logged on, also on battery, and catches up after sleep. It removes the task of the older design, `agent-codereview supervisor`, if present. `-Remove` uninstalls.

## Try it by hand

```bash
bash scripts/poll.sh --dry-run            # what a pass would do now
bash scripts/run_review.sh 1371 --test    # a full review of PR 1371, not posted
bash scripts/run_review.sh 1371 --test --reviewer-model opus   # the same on another reviewer model
bash scripts/run_review.sh 1371           # review PR 1371 and post it
bash tests/classify.sh                    # checks the classification rules; needs gh logged in
bash scripts/watch_pr_updates.sh --dry-run   # what a watcher pass would send now
bash tests/watch_pass.sh                  # whole watcher passes against stubs; needs only node
bash scripts/measure_context.sh           # the fixed context of a lean run (about 1 cent)
```

A run's prompt, the reviewer's prompt, the review body and Claude's JSON result stay in `state/runs/<n>-<time>/` for 14 days. `state/reviews.log` has one line per run with its cost. The watcher logs to `state/poll.log` and keeps its ledger in `state/pr_updates/`.

## Cost controls

| Setting | Effect |
|---|---|
| `ORCHESTRATOR_MODEL`, `REVIEWER_MODEL` | Models of the run and of its reviewer subagent. |
| `REVIEWER_MODEL_SMALL`, `SMALL_PR_MAX_LINES`, `RISKY_PATHS` | A change of at most this many lines that touches no risky path is reviewed on the smaller model. |
| `MAX_CHANGE_ROUNDS` | After this many change requests on a PR, new commits stop starting re-reviews; the author gets one comment, and a re-request still works. |
| `MAX_RUN_USD`, `RUN_TIMEOUT_MINUTES` | A run is stopped at this spend or time. |
| `MAX_ATTEMPTS` | Failed runs per PR head before it is left to you, with a notification. |
| `MAX_PARALLEL_REVIEWS` | Reviews running at once. |
| `REREVIEW_SETTLE_SECONDS` | Quiet time before a re-review, so a run of fix-up pushes costs one review. |
| `PR_UPDATE_ENABLED` | `false` turns the PR update watcher off. |
| `PR_UPDATE_RESUME_RETIRED` | `false` stops the watcher from resuming retired sessions; their updates wait until the session is live again, with an "update waiting" notification. |
| `PR_UPDATE_MAX_RESUMES_PER_PASS` | Retired sessions resumed in one pass (2). The rest wait for the next pass. |
| `PR_UPDATE_MAX_PER_PR_PER_DAY` | Messages to sessions about one PR in 24 hours (6). Later updates are dropped, with a notification. |
| `PR_UPDATE_IGNORE_LOGINS` | Logins whose comments and reviews are not updates, besides `MY_LOGINS`, which are always ignored. Empty means `dependabot[bot]`. |

## When a PR is reviewed again

A teammate's PR is re-reviewed when it has moved past the commit your last review was on, and one of these is true:

- your last review requested changes;
- your approval was dismissed by the new commits (`REREVIEW_DISMISSED_APPROVALS=true`);
- you were requested as reviewer again.

For the first two, the pass waits until the PR has had no new commits for `REREVIEW_SETTLE_SECONDS` (30 minutes by default) and its CI checks have finished without a failure. A re-request is acted on at once, whatever the checks say. The re-review checks whether each earlier finding was dealt with and reviews the new commits; for a small change it checks them itself instead of starting a reviewer. A rebase that changes nothing is approved again by `run_review.sh` itself, without starting Claude at all.

After `MAX_CHANGE_ROUNDS` change requests (5 by default) new commits no longer start a re-review. The author gets one comment asking to re-request your review or talk it through, and you get a notification.

## Updates on your sessions' PRs

A teammate answers a PR hours after the Claude Code session that opened it went quiet. Without the watcher you have to notice, find the session and paste the link. With it, the session is told. Each pass reads the new comments and reviews on the PRs your sessions own and sends the owning session one message: `There is an update on PR <url>: a review requesting changes and 2 comments from <logins>. Check it out whether any action is needed and proceed if it is.` The message names the PR, the kinds of update and who wrote them. It never contains a comment's text; the session reads the comment itself with `gh`.

**Which sessions.** The ones `claude agents --json --all` lists: live sessions (with a process) and retired background sessions (no process, job state kept). A closed interactive session, and one deleted with `claude rm`, is not watched, and its PRs are forgotten with it.

**Which PRs.** Those found in a session's transcript, in any repository `gh` can read. A session owns a PR through the best of three sources:

| Source | Meaning |
|---|---|
| `created` | The session ran `gh pr create`: a tool result of at most three lines whose last line is the PR's URL. |
| `linked` | Claude Code's own PR link record, written whenever a PR URL goes by in the session. The session saw the PR; it may not have made it. |
| `mentioned` | A PR URL you typed to the session. |

When several sessions name one PR, one gets the message: the best source wins, then a live session over a retired one, then the one started last.

**What counts as an update.** A comment, a review comment or a review from anyone not in `PR_UPDATE_IGNORE_LOGINS` (always `MY_LOGINS`, so a session's own replies never wake it, plus `dependabot[bot]` and `infusemedia`, the account that posts the automated scan reports, in the shipped `config.env`). Several updates on one PR in one pass make one message. A merged or closed PR gets one notice and is then forgotten. The notice goes to a live session only, and not at all when the merger or closer is one of `MY_LOGINS`. A PR seen for the first time is enrolled silently: what is already on it does not count (see `--backfill` below).

**Merge conflicts.** When one of your PRs (author in `MY_LOGINS`) conflicts with its base branch, its session is told once: `There is an update on PR <url>: merge conflicts with master: rebase it onto master, resolve them, run the tests and push. ...`. This also goes out when the PR already conflicts the first time the watcher sees it. The session is told again only after GitHub has called the PR mergeable in between, so a PR that stays in conflict does not wake its session every pass. If new comments arrive in the same pass, they go out in the same message. A teammate's PR is never reported this way, even when one of your sessions names it, because the session must not rebase someone else's branch. The watcher reads the conflict from the `gh pr list` it already makes, so this costs no extra call. A push to the base branch does not change a PR's update time; that is why the watcher checks mergeability on every pass. While GitHub is still working mergeability out (`UNKNOWN`), the watcher changes nothing. The caps and the resume of a retired session apply as for any update. A conflict dropped by the daily cap, or given up after two failed deliveries, is not reported again until it has cleared. When `master` moves under several of your PRs, each conflicting one wakes its session.

**How a session is told.**

- A live session gets the message in its inbox. By default Claude Code holds it there as a peer message with a "Deliver" prompt until you approve it in the session: a session running with permission prompts bypassed holds a message whose sender did not attest a permission mode, and an external script has no way to attest one. This happened in the test and in the first live run on this machine. To have it delivered without the prompt, see "Deliver to live sessions without a click" below. The watcher never changes your settings, and it cannot tell a held message from a delivered one, so the notification is how you find out.
- A retired background session is resumed with `claude --bg --resume <session id> "<message>"`, run in the folder the session ran in, and starts on the update at once. It then stays running until Claude Code retires it again, about an hour idle on this machine. A retired session whose folder is gone is never resumed; you get a notification and carry the message by hand. Only background sessions are ever resumed.

**Deliver to live sessions without a click.** Add this top-level line to `~/.claude/settings.json`, your user settings, not this repository's:

```json
"crossSessionInbound": "accept"
```

A live session then hands the watcher's message to Claude at once, with no "Deliver" prompt. The setting is Claude Code's own and covers every peer message a session receives, not only the watcher's: messages from your other Claude sessions also arrive unreviewed. Only a process running as you can reach a session's inbox, since it needs the token under `~/.claude/sessions/`. A session started after the change uses it; one already running may need a restart. To go back to the prompt, set it to `"hold"` or remove the line. This machine runs with it since 2026-10-29.

**Cost.** A message to a live session costs no resume; the session still spends tokens acting on it. A resume is expensive: it re-reads the session's whole context on the session's own model, and then works with nobody watching. On this machine the sessions run on opus and hold 100K tokens and more. `PR_UPDATE_MAX_RESUMES_PER_PASS` and `PR_UPDATE_MAX_PER_PR_PER_DAY` bound how many wake-ups there are, not what each one costs. With `PR_UPDATE_RESUME_RETIRED=false` nothing is resumed: the update of a retired session waits until that session is live again, and you get one "update waiting" notification for it.

**Notifications.** A message sent gives "PR #n: update" ("PR #n: merge conflicts" for a conflict), with the summary and the session. A message that could not be sent is tried once more on the next pass, then dropped with "carry the message by hand". A resume that says it started a copy of the session is dropped that way at once, since another try could start another copy. A PR over its daily cap gives "update not forwarded". An update for a retired session while `PR_UPDATE_RESUME_RETIRED` is off gives "update waiting", once per new update. If the sessions cannot be listed you get "PR watcher cannot list sessions"; see `state/poll.log`. The events are `NOTIFIED`, `NOT_DELIVERED`, `WATCH_GAVE_UP`, `CAPPED_UPDATES`, `WAITING` and `WATCH_FAILED`, and are also in `state/events.log`.

**Try it first.**

```bash
bash scripts/watch_pr_updates.sh --dry-run             # what a pass would send; nothing is sent or recorded
bash scripts/watch_pr_updates.sh --backfill --dry-run  # the same, counting what is already on newly seen PRs
bash scripts/watch_pr_updates.sh --backfill            # send it
```

`--dry-run` works on a throwaway copy of the ledger and prints each event as `DRY_RUN <event>`. A first dry run prints nothing, because every PR is enrolled silently; `--backfill --dry-run` shows what the waiting reviews would send. `--backfill` makes the comments and reviews already on a newly seen PR count as new, instead of enrolling it silently. Run it once after install to hand your sessions the reviews that are waiting; the caps apply. It does not touch a PR seen before.

The ledger is `state/pr_updates/`: which session owns which PR, what was handled, sent and is waiting, and which of your PRs' conflicts were reported. `AGENT.md` lists its files.

## Your own PRs that wait for nobody

A reviewer can leave only comments ("Verdict: comment. Nothing blocks the merge.") and never approve. If the session that owns the PR has nothing to change, nobody re-requests a review, and the PR sits unapproved with no review pending. #1416 waited like this until a second reviewer was asked by hand.

Each pass looks for your ready PRs that GitHub says still need a review, with no reviewer requested, whose last review is at least `STALLED_AFTER_MINUTES` (30) old. Once per PR head you get a notification, "PR #n is waiting for nobody". If `STALLED_PR_REVIEWER` is set, that login is requested too. The reviewer who only commented is not asked again, because it would comment again.

```bash
STALLED_PR_REVIEWER=""            # notify only (default)
STALLED_PR_REVIEWER="MaxPyrko"    # also request this reviewer
```

## PRs it ignores

A PR is ignored completely (no review, no re-review, no reviewer request) when its title contains one of the keywords in `SKIP_TITLE_KEYWORDS`:

```bash
SKIP_TITLE_KEYWORDS=("S.Y.S.T.E.M")
SKIP_TITLE_KEYWORDS=("S.Y.S.T.E.M" "do not review")   # several, spaces allowed
SKIP_TITLE_KEYWORDS=()                                 # ignore nothing
```

The match is plain text and ignores case. It applies to everyone's PRs, yours included. Dependabot and authors outside `WATCHED_AUTHORS` are always ignored.

## Drafts

A teammate's draft PR is reviewed when your review is requested on it. To review every draft from `WATCHED_AUTHORS`, requested or not, set `REVIEW_DRAFTS=true`. Your own drafts never get a reviewer requested until they are ready.

## Install the irl skill

```bash
mkdir -p ~/.claude/skills/irl && cp skills/irl/SKILL.md ~/.claude/skills/irl/
```

Then `/irl <quote>` in any session, or ask to see something "in real life".

## Limits

- The scheduled task runs only on Windows and only while you are logged on. The scripts themselves are plain bash; on another system, run `scripts/poll.sh` from cron.
- At most 100 open PRs are looked at per pass.
- New commits on a PR you approved are not re-reviewed while the approval stands and nobody re-requests you.
- The watcher reads Claude Code's internals: the session registry, job state, transcript records and the inbox. None is a stable interface, and a Claude Code update can break any of them. When the sessions cannot be listed you get a notification; other breakage may only show as updates that do not arrive.
- The watcher resumes only background sessions. A closed interactive session is not watched.
- Any tool result of at most three lines whose last line is a PR URL counts as the session creating that PR, so a session that merely printed one can own it.
- Per PR the watcher reads the first 100 comments, review comments, reviews and timeline events, and per repository the first 100 open PRs. A PR beyond that is not checked for updates.
- Like the reviewer, the watcher runs only while the scheduled task does.
