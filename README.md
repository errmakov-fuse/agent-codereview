# agent-codereview

A Claude Code session that watches a GitHub repository and reviews pull requests for you. It requests you as reviewer on your teammates' new PRs, reviews each one with a reviewer subagent briefed from the superpowers `requesting-code-review` template, and posts the findings as an approval or a change request. When a PR it asked changes on gets new commits, it reviews it again. It also puts a reviewer on your own PRs when they have none.

## What is in here

| Path | What it is |
|---|---|
| `AGENT.md` | The runbook the session follows: who to react to, who to ask for review, how to review, how to post. |
| `config.env` | Repository, logins, paths and intervals. The only file to edit for another repo or team. |
| `scripts/watch_prs.sh` | Polls the open PRs. Costs no tokens; wakes the session only when a PR needs review. |
| `scripts/watchdog.sh` | Tells the session whether the watcher is alive and what it missed. |
| `scripts/lib.sh` | Shared config loading and helpers. |
| `scripts/classify.jq` | The rules that decide which open PRs need a first review, a re-review, or a reviewer. |
| `scripts/compare_patch.sh` | Tells whether a force-pushed PR still contains what was reviewed, so an unchanged one can be approved again cheaply. |
| `tests/classify.sh` | Checks those rules against made-up PRs in `tests/classify_cases.json`. |
| `windows/supervise.ps1` | Runs outside Claude: starts a new review session when none is watching, and notifies you. |
| `windows/install.ps1` | Registers the scheduled task that runs the supervisor (`-Remove` deletes it). |
| `prompts/reviewer.md` | The reviewer subagent's prompt: the superpowers `requesting-code-review` template (MIT), with working rules that keep a review to about 25 tool calls. |
| `prompts/project-context.md` | What the reviewer must know about the watched repository. Edit it for another repo. |
| `scripts/claude_lean.sh` | Runs `claude -p` with a context of about 10K tokens instead of 51K: no global rules, plugins, MCP servers or unused tools. |
| `scripts/measure_context.sh` | Prints that fixed context, to check after a Claude Code update. |
| `claude/lean-settings.json` | The settings `claude_lean.sh` runs with. |
| `skills/irl/` | The `irl` skill: shows one concrete case for a statement that is too abstract. |

## Requirements

- Claude Code. The superpowers plugin is not needed: its reviewer template is copied, with changes, into `prompts/reviewer.md`.
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

The session starts the watcher in the background and reports each review as it is posted. It does not poll anything itself: the supervisor below notices a watcher that has stopped.

To keep the watcher from being stopped when the machine is short on memory, start Claude Code with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` in its environment.

## Keep it running across reboots

The session, its watcher and its watchdog all end when Claude Code exits or the machine restarts, and nothing inside Claude can notice that. Install the supervisor once:

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

It registers a scheduled task for your user (no administrator rights) that runs `windows\supervise.ps1` every 10 minutes while you are logged on. Each run:

| Situation | What it does |
|---|---|
| The watcher's heartbeat is fresh | Nothing. |
| The heartbeat is stale and no session named `AGENT_SESSION_NAME` is running | Starts one in the background (`claude --bg`) with `AGENT.md` as its prompt, and shows a notification. |
| The heartbeat is stale but such a session is listed | Waits. After 15 minutes of silence it starts a new session anyway: a session restored after a reboot has lost its watcher. |
| It has already started 6 sessions today | Starts nothing more and notifies you once. |

The new session runs with your default permission mode. Nothing is lost across the gap: on start the agent picks up every PR still waiting. What happened is in `state\supervise.log`; `claude agents` lists the sessions.

```powershell
powershell -ExecutionPolicy Bypass -File windows\supervise.ps1 -DryRun    # what it would do now
powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Remove      # uninstall
```

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

For the first two, the watcher waits until the PR has had no new commits for `REREVIEW_SETTLE_SECONDS` (30 minutes by default) and its CI checks have finished without a failure, so several fix-up pushes cost one review and a PR with red checks is left to its author. A re-request is acted on at once, whatever the checks say. The re-review checks whether each earlier finding was dealt with and reviews the new commits; it does not repeat the full review.

A rebase or squash that changes nothing costs no review at all. The agent first runs `scripts/compare_patch.sh`, which compares the PR's patch at the commit you approved with the patch at the new head. If they are the same, or differ by a few lines it can read and confirm as behaviour-neutral, it approves again and says so; otherwise it does the full re-review.

```bash
bash scripts/compare_patch.sh 1230 a8b482c4adf266553e304f43a713841659d42bcb
```

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

- A stopped watcher is noticed by the supervisor only, so without its scheduled task nothing restarts the watching.
- The supervisor runs only while you are logged on to Windows, and only on Windows.
- New commits on a PR you approved are not re-reviewed while the approval stands and nobody re-requests you.
- At most 100 open PRs are looked at per poll.
