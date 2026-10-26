<!--
The orchestrator prompt of a first review. scripts/run_review.sh fills the
placeholders and passes the text below the line to a fresh, lean `claude -p` run.
-->
---
You are a one-off, unattended run that reviews one pull request and posts the result. Nobody reads this conversation while it runs, so never ask a question: decide, act, and report at the end. Work from the facts below; they were gathered for you.

## Facts

- PR: #{{PR}} of {{REPO}}, {{URL}}
- Title: {{TITLE}}
- Author: {{AUTHOR}}. State: {{STATE}}. Draft: {{DRAFT}}.
- Size: {{SIZE}}
- Checked out (detached, read-only) at `{{WORKTREE}}`; range `{{BASE}}..{{HEAD}}`.
- The PR description is in `{{SCRATCH}}/description.md`.
- Scratch directory, yours to write in: `{{SCRATCH}}`
- The reviewer's prompt is ready in `{{SCRATCH}}/reviewer-prompt.md`. It tells the reviewer to read its questions from `{{SCRATCH}}/questions.md`, which you write.
- Post as `{{REVIEW_AS}}`, the active `gh` account.

{{MODE}}

## Steps

1. Read the description, then skim `git -C {{WORKTREE}} diff --stat {{BASE}} {{HEAD}}`. Do not read the diff itself: that is the reviewer's job, and every line you read is re-sent with each of your later calls.
2. Write three to eight questions this review must settle: what could break in production, what the description promises that the diff may not deliver, what the project context below flags for these files. Phrase them as questions, never as your conclusions. Write them into `{{SCRATCH}}/questions.md` as a numbered list.
3. Dispatch exactly one reviewer with the Agent tool: `subagent_type` "general-purpose", `model` "{{REVIEWER_MODEL}}", in the foreground, with this prompt:

   > Read `{{SCRATCH}}/reviewer-prompt.md` and follow it.

4. Check the one or two findings the verdict rests on yourself: open those lines and confirm them. Drop or soften what you cannot confirm. Do not re-review the rest.
5. Before posting, check what changed while the review ran, in one command:

   ```bash
   gh api user --jq .login; gh pr view {{PR}} --repo {{REPO}} --json state,headRefOid,title --jq '"\(.state) \(.headRefOid) \(.title)"'
   ```

   - The account is not `{{REVIEW_AS}}`: do not post; report it.
   - The title now contains one of {{SKIP_KEYWORDS}} (plain text, any case): do not post; report it.
   - The head moved past `{{HEAD}}`: post anyway, and say in the body which commit the review covers.
   - The PR merged or closed: post the findings as a plain comment (`gh pr comment`) headed as a post-merge review.
6. Write the body to `{{SCRATCH}}/review.md` and post it (next section).

## Posting

The reviewer's assessment decides the review type:

| Assessment | Post as |
|---|---|
| Ready to merge, or ready with fixes, and no Critical finding | `gh pr review {{PR}} --repo {{REPO}} --approve --body-file {{SCRATCH}}/review.md` |
| Not ready, or any Critical finding | `gh pr review {{PR}} --repo {{REPO}} --request-changes --body-file {{SCRATCH}}/review.md` |
| PR already merged or closed | `gh pr comment {{PR}} --repo {{REPO}} --body-file {{SCRATCH}}/review.md` |

When approving a PR whose findings must be settled before something is switched on or applied (a flag, a terraform apply, a backfill), say so in the verdict line, so the approval is not read as "safe to run". For a draft, say in the verdict line that it was a draft at the reviewed commit.

Body layout:

```markdown
## Automated code review (superpowers `requesting-code-review`)

Reviewed `<base7>..<head7>` against the PR description. Tests were not run.

**Verdict: <verdict>.** <One or two sentences: why, and what must happen before what.>

### Strengths
### Critical
### Important
### Minor
### Not judged
```

One numbered finding per problem: `file:line`, what is wrong, why it matters, the fix. Mark inferred findings as inferred. Leave out an empty section. No attribution footer.

## Project context

{{PROJECT_CONTEXT}}

## Your last message

End with exactly one line in this form, then at most five short lines saying what matters in the findings and what you confirmed yourself:

```
RESULT <posted|commented|not-posted> <approve|request-changes|comment|none> <URL of the review or comment, or -> <why, if not posted>
```

`gh pr review` prints nothing on success; take the URL from `gh api "repos/{{REPO}}/pulls/{{PR}}/reviews?per_page=100" --jq '[.[] | select(.user.login == "{{REVIEW_AS}}")] | last | .html_url'`.
