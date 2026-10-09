# agent-codereview

A Claude Code session that watches a GitHub repository and reviews pull requests for you. It requests you as reviewer on your teammates' new PRs, reviews each one with the superpowers `requesting-code-review` skill, and posts the findings as an approval or a change request. When a PR it asked changes on gets new commits, it reviews it again. It also puts a reviewer on your own PRs when they have none.

## What is in here

| Path | What it is |
|---|---|
| `AGENT.md` | The runbook the session follows: who to react to, who to ask for review, how to review, how to post. |
| `config.env` | Repository, logins, paths and intervals. The only file to edit for another repo or team. |
| `scripts/watch_prs.sh` | Polls the open PRs. Costs no tokens; wakes the session only when a PR needs review. |
| `scripts/watchdog.sh` | Tells the session whether the watcher is alive and what it missed. |
| `scripts/lib.sh` | Shared config loading and helpers. |
| `scripts/classify.jq` | The rules that decide which open PRs need a first review, a re-review, or a reviewer. |
| `tests/classify.sh` | Checks those rules against made-up PRs in `tests/classify_cases.json`. |
| `skills/irl/` | The `irl` skill: shows one concrete case for a statement that is too abstract. |

## Requirements

- Claude Code, with the superpowers plugin: `claude plugin install superpowers@claude-plugins-official`
- `gh`, logged in as the account in `REVIEW_AS`, with write access to the watched repository
- Git Bash (Windows) or any bash; `jq` is not needed
- A local clone of the watched repository at `LOCAL_CHECKOUT`

## Start it

1. Clone this repository and edit `config.env`.
2. Start Claude Code in the watched repository's checkout and give it:

   ```text
   Read C:/Users/DenisErmakov/www/agent-codereview/AGENT.md and follow it.
   ```

   Use the path where you cloned this repository.

The session starts the watcher in the background, schedules the watchdog every 10 minutes, and reports each review as it is posted.

To keep the watcher from being stopped when the machine is short on memory, start Claude Code with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` in its environment.

## Try the scripts by hand

```bash
bash scripts/watch_prs.sh --once --dry-run   # one poll; prints what it would request
bash scripts/watchdog.sh                     # ALIVE, or DEAD plus the PRs needing action
```

`watch_prs.sh --once` prints `QUIET` when nothing needs review, or `NEEDS_REVIEW <numbers>` and/or `NEEDS_REREVIEW <number>@<head sha>`.

```bash
bash tests/classify.sh                       # checks the classification rules; needs gh logged in
```

## When a PR is reviewed again

A teammate's PR is re-reviewed when it has moved past the commit your last review was on, and one of these is true:

- your last review requested changes;
- your approval was dismissed by the new commits (`REREVIEW_DISMISSED_APPROVALS=1`);
- you were requested as reviewer again.

For the first two, the watcher waits until the PR has had no new commits for `REREVIEW_SETTLE_SECONDS` (10 minutes by default), so several fix-up pushes cost one review. A re-request is acted on at once. The re-review checks whether each earlier finding was dealt with and reviews the new commits; it does not repeat the full review.

Runtime state (the handled list, the heartbeat, the log) is written to `state/`, which is not committed. Set `AGENT_CODEREVIEW_STATE` to put it elsewhere, and `AGENT_CODEREVIEW_CONFIG` to use another config file.

## PRs it ignores

A PR is ignored completely (no review, no re-review, no reviewer request) when its title contains one of the keywords in `SKIP_TITLE_KEYWORDS`:

```bash
SKIP_TITLE_KEYWORDS=("S.Y.S.T.E.M")
SKIP_TITLE_KEYWORDS=("S.Y.S.T.E.M" "do not review")   # several, spaces allowed
SKIP_TITLE_KEYWORDS=()                                 # ignore nothing
```

The match is plain text and ignores case. It applies to everyone's PRs, yours included. Dependabot and authors outside `WATCHED_AUTHORS` are always ignored.

## Drafts

A teammate's draft PR is reviewed when your review is requested on it. To review every draft from `WATCHED_AUTHORS`, requested or not, turn the knob on:

```bash
REVIEW_DRAFTS=false   # only drafts you are requested on (default)
REVIEW_DRAFTS=true    # all of them, like ready PRs
```

With the knob off, a draft you already reviewed is looked at again only when you are requested again. Your own drafts never get a reviewer requested until they are ready.

## Install the irl skill

```bash
mkdir -p ~/.claude/skills/irl && cp skills/irl/SKILL.md ~/.claude/skills/irl/
```

Then `/irl <quote>` in any session, or ask to see something "in real life".

## Limits

- The watchdog schedule lives in the session: it ends when Claude Code exits, and recurring jobs expire after 7 days.
- New commits on a PR you approved are not re-reviewed while the approval stands and nobody re-requests you.
- At most 100 open PRs are looked at per poll.
