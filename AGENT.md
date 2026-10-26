# PR review agent: notes for a Claude session

Nothing here needs a long-lived session any more. A Windows scheduled task runs `scripts/poll.sh` every few minutes; each PR that needs a review gets its own fresh, headless Claude run (`scripts/run_review.sh`), which posts the review and exits. Read this file when the owner asks you about the reviewer, or asks you to review a PR by hand.

`AGENT_HOME` below is the directory this file is in. Names and paths are in `config.env`.

## Who is who, and what gets reviewed

| Role | Config value | Meaning |
|---|---|---|
| Me | `MY_LOGINS` | PRs from these logins are mine. A review from any of them counts as my review. |
| Reviewing account | `REVIEW_AS` | Requested as reviewer on watched PRs; reviews are posted from it, so it must be the active `gh` account. |
| Watched authors | `WATCHED_AUTHORS` | Their new PRs get a code review. |
| My reviewer | `MY_PR_REVIEWER` | Requested on my PRs that have no reviewer. |

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

## Where to look when something went wrong

| File | Content |
|---|---|
| `state/events.log` | Every event the scheduled task saw: started, posted, failed, gave up. |
| `state/reviews.log` | One line per run: key, cost, Claude session id, and its RESULT line. |
| `state/poll.log` | Reviewer requests, `gh` errors, run starts and ends. |
| `state/runs/<n>-<time>/` | One run: the prompt it got, the reviewer prompt, the review body, Claude's JSON result. Kept for 14 days. |
| `state/attempts.txt` | Runs per key; at `MAX_ATTEMPTS` the PR is left alone and listed in `state/gave_up.txt`. Delete its lines to let it be tried again. |
| `state/handled_prs.txt` | `own-<n>`: my PRs that got their reviewer. |
| `state/capped.txt` | PRs that reached `MAX_CHANGE_ROUNDS` and got the one comment saying so. |
| `state/last_poll` | When the last pass listed the PRs. Older than ten minutes while you are logged on means the scheduled task is not running. |

`schtasks /Query /TN "agent-codereview poll"` shows whether the task is installed. A run's transcript is a normal Claude Code session: `claude --resume <session id>` from `AGENT_HOME`.

## Known traps

- **Account changes.** If `gh api user` stops printing `REVIEW_AS`, or a reviewer request fails with "Reviews may only be requested from collaborators", tell the owner. When teammates change logins, their PRs silently stop being picked up: list recent PR authors (`gh pr list --state all --limit 40 --json author`) and update `config.env`, keeping old logins while their PRs are open.
- **`gh pr edit --add-reviewer`** fails on this repository with a "Projects (classic)" deprecation error. Request reviewers through the REST API, as `lib.sh` does.
- **Private repositories under another account.** If `git clone` or `push` says "Repository not found", git is using a stored credential for a different account. Use `gh`'s token: `git -c credential.helper= -c credential.helper='!gh auth git-credential' <command>`.
- **Prompt changes.** Try them with `run_review.sh <n> --test` on a recent PR before merging; the run's directory shows what it produced.
