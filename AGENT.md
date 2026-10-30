# PR review agent: notes for a Claude session

Nothing here needs a long-lived session any more. A Windows scheduled task runs `scripts/poll.sh` every few minutes; each PR that needs a review gets its own fresh, headless Claude run (`scripts/run_review.sh`), which posts the review and exits. A second script, `scripts/watch_pr_updates.sh`, runs before `poll.sh` in each pass and talks to the owner's own sessions: it tells the session that opened a PR when somebody comments on it or reviews it. Read this file when the owner asks you about the reviewer, or asks you to review a PR by hand.

`AGENT_HOME` below is the directory this file is in. Names and paths are in `config.env`.

## Who is who, and what gets reviewed

| Role | Config value | Meaning |
|---|---|---|
| Me | `MY_LOGINS` | PRs from these logins are mine. A review from any of them counts as my review. |
| Reviewing account | `REVIEW_AS` | Requested as reviewer on watched PRs; reviews are posted from it, so it must be the active `gh` account. |
| Watched authors | `WATCHED_AUTHORS` | Their new PRs get a code review. |
| My reviewer | `MY_PR_REVIEWER` | Requested on my PRs that have no reviewer. |
| Fallback reviewer | `STALLED_PR_REVIEWER` | Requested on my PR that still needs an approval when its reviews are only comments and nobody is requested (after `STALLED_AFTER_MINUTES`). Empty means I only get a notification. |

- A watched author's PR with no review from me gets a first review.
- It gets a re-review when its head has moved past the commit of my last review and either I requested changes, my approval was dismissed (`REREVIEW_DISMISSED_APPROVALS`), or my review was requested again. The first two wait for `REREVIEW_SETTLE_SECONDS` of a quiet head and for green CI checks; a re-request acts at once.
- After `MAX_CHANGE_ROUNDS` change requests on a PR, new commits stop starting re-reviews; the author gets one comment and a re-request still works.
- Drafts are reviewed only when my review is requested on them, unless `REVIEW_DRAFTS=true`.
- A PR whose title contains one of `SKIP_TITLE_KEYWORDS` (`S.Y.S.T.E.M`) is ignored completely. If the owner asks for such a PR by name, review it by hand: the keyword stops the automatic reaction, not a direct request.

The rules live in `scripts/classify.jq`, with tests in `tests/classify.sh`.

## Verdict and review type

| Reviewer's verdict | Posted as |
|---|---|
| Ready to merge, or ready with fixes, and no Critical finding | approve |
| Not ready, or any Critical finding | request changes |
| PR already merged or closed | plain comment |

Reviews are titled "Automated code review" or "Automated re-review" and carry no attribution footer. The full posting rules are in `prompts/run-review.md` and `prompts/run-rereview.md`.

## Doing things by hand

```bash
bash "$AGENT_HOME/scripts/run_review.sh" 1380              # review PR 1380 now and post it
bash "$AGENT_HOME/scripts/run_review.sh" 1380 --test       # the same, without posting
bash "$AGENT_HOME/scripts/poll.sh" --dry-run               # what the next pass would do
```

Without more arguments a run is a first review. For a re-review by hand, pass the PR's current head and a reason, `run_review.sh 1380 <head sha> rerequested`; the run then finds my last review and checks its findings.

Do not review a PR inside your own session when a run can do it: your session carries far more context than a lean run, so the same review costs several times more.

## PR updates to sessions

`scripts/watch_pr_updates.sh` finds the PRs in the owner's Claude Code sessions' transcripts and, when a PR gets a comment or review from someone outside `PR_UPDATE_IGNORE_LOGINS`, sends its owning session a message with the PR link, the kinds of update and the commenters (never the text). A live session gets it in its inbox; a retired background session is resumed with `claude --bg --resume`. It also tells the session once when one of the owner's own PRs goes into merge conflict with its base, read from the same `gh pr list` (`mergeable`), and again only after the PR was mergeable in between. README has the rules; the settings are the `PR_UPDATE_*` lines in `config.env`. A PR seen for the first time is enrolled silently, so nothing is sent for what was already on it; a conflict it already has is still reported.

To have a conflict reported again while it lasts, delete the PR's row from `state/pr_updates/conflicts.tsv`.

```bash
bash "$AGENT_HOME/scripts/watch_pr_updates.sh" --dry-run     # what a pass would send; nothing is sent or recorded
bash "$AGENT_HOME/scripts/watch_pr_updates.sh"               # one real pass, as the scheduled task runs it
bash "$AGENT_HOME/scripts/watch_pr_updates.sh" --backfill    # PRs seen for the first time count what is already on them
```

A real pass sends messages, and resuming a session costs tokens. Run it for real only when the owner asks, and run `--dry-run` first. A dry run reads the sessions and GitHub but works on a copy of the ledger, so it records nothing.

To send the waiting reviews and comments on a watched PR again: delete its row from `state/pr_updates/seen.tsv` and run `--backfill`. Only PRs with no `seen.tsv` row are read from the start.

To watch a PR the watcher forgot (a row in `closed.txt`): delete that row, delete its session's row in `scan.tsv`, which makes the transcript be read again, and, to start from a clean slate, its `seen.tsv` row. Left in place, the `seen.tsv` row makes the next pass report what happened since the old one.

## Where to look when something went wrong

| File | Content |
|---|---|
| `state/events.log` | Every event the scheduled task saw: started, posted, failed, gave up. |
| `state/reviews.log` | One line per run: key, cost, Claude session id, and its RESULT line. |
| `state/poll.log` | Reviewer requests, `gh` errors, run starts and ends; also what the PR update watcher logged: skipped repositories, failed deliveries, resumes. |
| `state/runs/<n>-<time>/` | One run: the prompt it got, the reviewer prompt, the review body, Claude's JSON result. Kept for 14 days. |
| `state/attempts.txt` | Runs per key; at `MAX_ATTEMPTS` the PR is left alone and listed in `state/gave_up.txt`. Delete its lines to let it be tried again. |
| `state/handled_prs.txt` | `own-<n>`: my PRs that got their reviewer. |
| `state/capped.txt` | PRs that reached `MAX_CHANGE_ROUNDS` and got the one comment saying so. |
| `state/stalled.txt` | `<n>@<head>`: my PRs reported as waiting for nobody at that head. |
| `state/pr_updates/watch.tsv` | Which session watches which PR: repo, number, session id, source (`created`, `linked`, `mentioned`), first seen. Rows are added as new transcript lines are scanned (`scan.tsv` remembers how far each was read) and dropped when their session is gone or the PR is forgotten. |
| `state/pr_updates/seen.tsv` | Per PR: the `updatedAt` last looked at and the newest comment or review already handled. No row means the PR is enrolled silently. |
| `state/pr_updates/sent.log` | One line per message: time, repo, number, session id, `inbox` or `resume`, `ok` or `failed`, summary. `ok` for an inbox message means written, not delivered. The daily cap counts only the `ok` rows of the last 24 hours. |
| `state/pr_updates/pending.tsv` | Updates not delivered yet: waiting for a resume slot, for a retired session while `PR_UPDATE_RESUME_RETIRED` is off (announced once by a `WAITING` event), or failed once. Tried every pass. |
| `state/pr_updates/closed.txt` | PRs the watcher has forgotten: merged, closed, or gone. |
| `state/pr_updates/conflicts.tsv` | The owner's PRs whose merge conflict their session was told about, with when. Cleared when GitHub calls the PR mergeable again, or when the PR is forgotten. |
| `state/pr_updates/sessions.tsv` | The sessions of the last pass: short id, session id, `live` or `retired`, pid, start time, folder, name. |
| `state/pr_updates/scan.tsv` | Per session: how many bytes of its transcript were read. Delete a row to read that transcript again; the watcher drops the row itself when the session leaves the listing, so a session that comes back is read again. |
| `state/pr_updates/unreachable.tsv` | Repositories GitHub would not resolve (see the traps). Cleared when one resolves again. |
| `state/pr_updates/lock/` | Present while a watcher pass runs; a lock whose process is gone is taken over. |
| `state/last_poll` | When the last pass listed the PRs. Older than ten minutes while you are logged on means the scheduled task is not running. |

`schtasks /Query /TN "agent-codereview poll"` shows whether the task is installed. A run's transcript is a normal Claude Code session: `claude --resume <session id>` from `AGENT_HOME`.

## Known traps

- **Account changes.** If `gh api user` stops printing `REVIEW_AS`, or a reviewer request fails with "Reviews may only be requested from collaborators", tell the owner. When teammates change logins, their PRs silently stop being picked up: list recent PR authors (`gh pr list --state all --limit 40 --json author`) and update `config.env`, keeping old logins while their PRs are open.
- **`gh pr edit --add-reviewer`** fails on this repository with a "Projects (classic)" deprecation error. Request reviewers through the REST API, as `lib.sh` does.
- **Private repositories under another account.** If `git clone` or `push` says "Repository not found", git is using a stored credential for a different account. Use `gh`'s token: `git -c credential.helper= -c credential.helper='!gh auth git-credential' <command>`.
- **A resumed session keeps running.** `claude --bg --resume` leaves the session alive until Claude Code retires it again, about an hour idle on this machine, so a burst of updates leaves several sessions awake and working. Its cost is the whole context re-read plus whatever it then does; `PR_UPDATE_MAX_RESUMES_PER_PASS` limits how many wake at once, not what each costs.
- **A held inbox message.** A live session may hold the watcher's message until the owner approves it in the session, unless `crossSessionInbound` is `"accept"` in `~/.claude/settings.json` (README, "Deliver to live sessions without a click"). The owner set it to `"accept"` on 2026-10-29. If the owner says a session ignored an update, look for `ok` in `sent.log` and ask whether the session shows a held message; a session started before the change may still hold. Do not change that setting unless the owner asks.
- **Claude Code internals.** The watcher reads the session registry, job state, transcript records and the inbox pipe, and none is a stable interface. After a Claude Code update, if updates stop arriving or `WATCH_FAILED` appears (it toasts when sessions cannot be listed), run `--dry-run` and read `state/poll.log` before blaming GitHub.
- **Repositories GitHub cannot resolve.** After `gh auth switch`, a private repository the current account cannot see answers `Could not resolve to a Repository`. The watcher then keeps that repository's PRs, skips it, logs the outage once in `poll.log`, and logs when it is reachable again. It forgets a PR (a row in `closed.txt`) when GitHub says that PR does not exist, and when the PR is merged or closed (after its notice, or silently when it was never seen open). A failed `gh pr list` skips the repository for the pass; a failed read of one PR skips only that PR. Both are logged every time.
- **A retired session whose folder is gone.** It is never resumed, since it would run in some other repository. The owner gets a notification and carries the message by hand.
- **Prompt changes.** Try them with `run_review.sh <n> --test` on a recent PR before merging; the run's directory shows what it produced.
