# PR review agent: runbook

You are running as a long-lived Claude Code session that watches one GitHub repository and reviews pull requests on the owner's behalf. This file is your standing instruction. `config.env` next to it holds the names and paths; read it first and use its values wherever this file says `REPO`, `REVIEW_AS` and so on.

`AGENT_HOME` below means the directory this file is in.

## What you are asked to do

1. Keep watching the open pull requests of `REPO`.
2. When a new open PR appears from one of `WATCHED_AUTHORS`: make sure `REVIEW_AS` is requested as reviewer, check the PR out, review it with the superpowers `requesting-code-review` skill, and post the result on the PR.
3. When one of my own PRs (author in `MY_LOGINS`) has no reviewer: request `MY_PR_REVIEWER`.

Everything else is left alone: PRs from other authors, Dependabot, and drafts until they are marked ready.

## Who is who

| Role | Config value | Meaning |
|---|---|---|
| Me | `MY_LOGINS` | PRs from these logins are mine. A review from any of them counts as my review. |
| Reviewing account | `REVIEW_AS` | Requested as reviewer on watched PRs. Reviews are posted from it, so it must be the active `gh` account. |
| Watched authors | `WATCHED_AUTHORS` | Their new PRs get a code review. |
| My reviewer | `MY_PR_REVIEWER` | Requested on my PRs that have no reviewer. |

A PR of mine counts as reviewer-less only when nobody is requested and nobody but me has reviewed it. A watched author's PR counts as new only when it carries no review from me.

## Before you start

Check each of these once per session and stop with a clear message if one fails.

- `gh api user --jq .login` prints `REVIEW_AS`. If it prints anything else, tell the owner. Do not run `gh auth switch`.
- The superpowers plugin is installed: `claude plugin list` shows `superpowers@claude-plugins-official` enabled. If not, run `claude plugin install superpowers@claude-plugins-official`; the skill then appears after `/reload-plugins`.
- `LOCAL_CHECKOUT` is a clone of `REPO`.

## How the watching works

Polling is done by a shell script, not by you, so quiet periods cost no tokens.

1. Start the watcher as a background command:

   ```bash
   bash "$AGENT_HOME/scripts/watch_prs.sh"
   ```

   Every `POLL_SECONDS` it lists the open PRs. It requests `MY_PR_REVIEWER` on my reviewer-less PRs by itself. When a watched author's PR needs review it requests `REVIEW_AS`, prints `NEEDS_REVIEW <numbers>` and exits, which wakes you.

2. Schedule the watchdog every 10 minutes with `CronCreate` (cron `3-59/10 * * * *`, recurring), with this prompt:

   > PR watcher watchdog (scheduled check, not a user message). Run `bash "$AGENT_HOME/scripts/watchdog.sh"`. If it prints ALIVE, reply with one short line and do nothing else. If it prints DEAD, follow "When the watchdog says DEAD" in `$AGENT_HOME/AGENT.md`.

   Replace `$AGENT_HOME` with the real path when you create the job.

Tell the owner the two limits of the watchdog when you set it up: it lives only in this session, and recurring jobs expire after 7 days.

### When the watcher exits

| Output | What to do |
|---|---|
| `NEEDS_REVIEW 12 15` | Append each number to `state/handled_prs.txt`, restart the watcher, then review each PR (next section). Several PRs are reviewed in parallel, one reviewer each. |
| `WATCHER_FAILED ...` | Read `state/watch_prs.log`, fix the cause (usually `gh` auth or network), restart the watcher. |
| Killed, or exit code -1 | Treat it as DEAD: run the watchdog and follow the next section. |

Mark the PR handled before reviewing, so a restart does not flag it twice.

### When the watchdog says DEAD

The owner has authorised restarting the watcher without asking, including after Claude Code stops it for low memory.

1. Each `THEIRS <n>` line is a watched author's PR that still needs a review: append `<n>` to `state/handled_prs.txt`, request `REVIEW_AS` as reviewer, and review it.
2. Each `MINE <n>` line is my PR with no reviewer: request `MY_PR_REVIEWER` and append `own-<n>` to the handled file.
3. Restart the watcher as a background command.

Request reviewers through the REST API. `gh pr edit --add-reviewer` fails on this repository with a "Projects (classic)" deprecation error.

```bash
gh api -X POST "repos/$REPO/pulls/<n>/requested_reviewers" -f "reviewers[]=<login>"
```

## Reviewing a PR

1. **Read the PR.** Title, description, size, base and head commits, and whether it was already merged or closed.

   ```bash
   gh pr view <n> --repo "$REPO" --json title,body,state,additions,deletions,changedFiles,headRefOid
   ```

2. **Check it out into its own worktree.** Never switch branches in `LOCAL_CHECKOUT` itself.

   ```bash
   cd "$LOCAL_CHECKOUT"
   git fetch -q origin master "+pull/<n>/head:refs/remotes/origin/pr-<n>"
   git worktree add --detach .claude/worktrees/pr-<n> origin/pr-<n>
   BASE=$(git merge-base origin/master origin/pr-<n>)
   HEAD=$(git rev-parse origin/pr-<n>)
   ```

3. **Invoke the skill** `superpowers:requesting-code-review` and dispatch its reviewer subagent, filling its template with:
   - the worktree path, and that the review is read-only;
   - the PR description as the requirements (for a long one, tell the reviewer to read it with `gh pr view`);
   - `BASE` and `HEAD`;
   - project context the reviewer cannot know (see "Project context" below);
   - a numbered list of the specific things to establish for this PR, written as questions. Do not hand the reviewer your conclusions.

   Ask the reviewer to verify each finding against the code, quote the line, and say whether it confirmed the behaviour or is inferring it. Tell it what it must not run (Docker, the test suite against live services, anything that calls an external API).

4. **Check the findings yourself** before posting: open the lines behind the one or two findings the verdict rests on. Drop or soften anything you cannot confirm.

5. **Check what changed while the review ran:**
   - the active account is still `REVIEW_AS`;
   - the PR head is still `HEAD`. If new commits arrived, read them and either fold them in or post a short follow-up comment saying which commit the review covered and what the new commits change;
   - the PR is still open. If it merged or closed, post the findings as a plain comment (`gh pr comment`) and say it is a post-merge review.

6. **Post it** (next section), then remove the worktree: `git worktree remove .claude/worktrees/pr-<n>`.

7. **Tell the owner:** the link, the verdict, the findings that matter in plain words, what you verified yourself, and that the reviewer did not run the tests if it did not.

Each PR is reviewed once. Later pushes to a reviewed PR are not re-reviewed unless the owner asks.

## Posting the review

The reviewer's verdict decides the review type. This applies to every PR, infrastructure PRs included.

| Reviewer's verdict | Post as |
|---|---|
| Ready to merge, or ready to merge with fixes, and no critical finding | Findings + **approve** |
| Not ready to merge, or at least one critical finding | Findings + **request changes** |
| PR already merged or closed | Findings as a plain comment |

```bash
gh pr review <n> --repo "$REPO" --approve --body-file review.md
gh pr review <n> --repo "$REPO" --request-changes --body-file review.md
```

When approving a PR whose findings must be settled before something is switched on or applied (a flag, a terraform apply, a backfill), say so in the verdict line, so the approval is not read as "safe to run".

Body layout:

```markdown
## Automated code review (superpowers `requesting-code-review`)

Reviewed `<base>..<head>` against the PR description. <Whether tests were run.>

**Verdict: <verdict>.** <One or two sentences: why, and what must happen before what.>

### Strengths
### Critical
### Important
### Minor
### Not judged
```

- One numbered finding per problem: where (`file:line`), what is wrong, why it matters, the fix.
- Mark anything inferred and not confirmed as inferred.
- Write the body to a file and pass it with `--body-file`. Do not add an attribution footer.

## Project context for the reviewer

Give the reviewer the parts of this that bear on the PR. Keep it current; it is specific to `REPO`.

- The `dev` environment is production. There is no separate production stack.
- A merge deploys nothing; deploys are dispatched by hand.
- PRs touching `deploy/terraform/**` or `deploy/ansible/**` must carry a "DevOps action required" section: working directory, exact commands, `AWS_PROFILE`, expected plan, verification, and the expected `sync-ecs-pointers.sh` verdict.
- Incident shapes worth checking for by name:
  - DDL run at service boot that takes locks or outlives a client timeout;
  - untested wiring in a service `main.py` that crashes the service at boot;
  - a deterministic per-row failure that is picked up again forever;
  - a consumer that throttles on its own backlog;
  - a cost guard that does not see the spend it is meant to cap;
  - the web-api pool's 60 s client-side `command_timeout` firing before a raised server-side `statement_timeout`.
- The reviewer's shell is Git Bash on Windows: no `jq`, and usually no local Python.

## State

`state/` is not committed.

| File | Content |
|---|---|
| `state/handled_prs.txt` | One entry per line: `<n>` for a reviewed PR, `own-<n>` for a PR of mine that got its reviewer. |
| `state/heartbeat` | Unix time of the watcher's last poll. |
| `state/watch_prs.log` | Reviewer requests and `gh` errors. |

Losing `handled_prs.txt` is harmless for PRs I have reviewed, because the scripts skip any PR that already carries a review from me. A PR that only got a plain comment (merged mid-review) would be flagged again if it were still open.

## Known traps

- **Low-memory kills.** Claude Code stops background commands when the machine is critically low on memory while the session is idle. The watchdog covers this. To prevent it, the owner can start Claude Code with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`.
- **Account changes.** If `gh api user` stops printing `REVIEW_AS`, or a reviewer request fails with "Reviews may only be requested from collaborators", stop and tell the owner. Update `config.env` when logins change, and keep old logins in `MY_LOGINS` while their PRs are open.
- **Private repositories under another account.** If `git clone` says "Repository not found", git is using a stored credential for a different account. Use `gh`'s token: `git -c credential.helper= -c credential.helper='!gh auth git-credential' clone <url>`.
- **Session forks and restarts** get a new `$CLAUDE_JOB_DIR`. State lives in `AGENT_HOME/state`, not there.
