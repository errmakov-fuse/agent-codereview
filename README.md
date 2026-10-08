# agent-codereview

A Claude Code session that watches a GitHub repository and reviews pull requests for you. It requests you as reviewer on your teammates' new PRs, reviews each one with the superpowers `requesting-code-review` skill, and posts the findings as an approval or a change request. It also puts a reviewer on your own PRs when they have none.

## What is in here

| Path | What it is |
|---|---|
| `AGENT.md` | The runbook the session follows: who to react to, who to ask for review, how to review, how to post. |
| `config.env` | Repository, logins, paths and intervals. The only file to edit for another repo or team. |
| `scripts/watch_prs.sh` | Polls the open PRs. Costs no tokens; wakes the session only when a PR needs review. |
| `scripts/watchdog.sh` | Tells the session whether the watcher is alive and what it missed. |
| `scripts/lib.sh` | Shared config loading and PR classification. |
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

`watch_prs.sh --once` prints `QUIET` when nothing needs review, or `NEEDS_REVIEW <numbers>`.

Runtime state (the handled list, the heartbeat, the log) is written to `state/`, which is not committed. Set `AGENT_CODEREVIEW_STATE` to put it elsewhere, and `AGENT_CODEREVIEW_CONFIG` to use another config file.

## Install the irl skill

```bash
mkdir -p ~/.claude/skills/irl && cp skills/irl/SKILL.md ~/.claude/skills/irl/
```

Then `/irl <quote>` in any session, or ask to see something "in real life".

## Limits

- The watchdog schedule lives in the session: it ends when Claude Code exits, and recurring jobs expire after 7 days.
- Each PR is reviewed once. New commits pushed to a reviewed PR are not re-reviewed unless you ask.
- Draft PRs are skipped until they are marked ready.
- At most 100 open PRs are looked at per poll.
