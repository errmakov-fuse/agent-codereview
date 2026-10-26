# agent-codereview

Reviews your teammates' pull requests for you with Claude Code. It requests you as reviewer on their new PRs, reviews each one with a reviewer subagent briefed from the superpowers `requesting-code-review` template, and posts the findings as an approval or a change request. When a PR it asked changes on gets new commits, it reviews it again. It also puts a reviewer on your own PRs when they have none.

## How it runs

A Windows scheduled task runs `windows/poll.ps1` every five minutes. That runs one pass of `scripts/poll.sh`, which lists the open PRs with `gh` and decides what needs doing. A pass that finds nothing costs no tokens.

Each PR that needs a review gets its own run of `scripts/run_review.sh`. It gathers the facts with `gh` and `git` (metadata, a checkout, the earlier review, a patch comparison), then starts a fresh headless Claude run that briefs one reviewer subagent, checks the findings the verdict rests on, posts, and exits. You get a Windows notification when a review starts and when it is posted.

There is no long-lived Claude session. That is where the cost was: a session that watched for weeks re-read its whole history, up to 965K tokens, on every wake-up, and a scheduled self-check every 10 minutes cost more than the reviews. A fresh run starts from about 10K tokens of context (`scripts/claude_lean.sh`) and is gone when the review is posted.

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
| `tests/classify.sh` | Checks the rules against made-up PRs in `tests/classify_cases.json`. |
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
bash scripts/run_review.sh 1371           # review PR 1371 and post it
bash tests/classify.sh                    # checks the classification rules; needs gh logged in
bash scripts/measure_context.sh           # the fixed context of a lean run (about 1 cent)
```

A run's prompt, the reviewer's prompt, the review body and Claude's JSON result stay in `state/runs/<n>-<time>/` for 14 days. `state/reviews.log` has one line per run with its cost.

## Cost controls

| Setting | Effect |
|---|---|
| `ORCHESTRATOR_MODEL`, `REVIEWER_MODEL` | Models of the run and of its reviewer subagent. |
| `MAX_RUN_USD`, `RUN_TIMEOUT_MINUTES` | A run is stopped at this spend or time. |
| `MAX_ATTEMPTS` | Failed runs per PR head before it is left to you, with a notification. |
| `MAX_PARALLEL_REVIEWS` | Reviews running at once. |
| `REREVIEW_SETTLE_SECONDS` | Quiet time before a re-review, so a run of fix-up pushes costs one review. |

## When a PR is reviewed again

A teammate's PR is re-reviewed when it has moved past the commit your last review was on, and one of these is true:

- your last review requested changes;
- your approval was dismissed by the new commits (`REREVIEW_DISMISSED_APPROVALS=true`);
- you were requested as reviewer again.

For the first two, the pass waits until the PR has had no new commits for `REREVIEW_SETTLE_SECONDS` (30 minutes by default) and its CI checks have finished without a failure. A re-request is acted on at once, whatever the checks say. The re-review checks whether each earlier finding was dealt with and reviews the new commits; for a small change it checks them itself instead of starting a reviewer. A rebase that changes nothing is approved again from the patch comparison, without a review.

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
