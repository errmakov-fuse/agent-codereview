#!/usr/bin/env bash
# Reviews one PR in a fresh, lean, headless Claude run and posts the result.
#
#   run_review.sh <n>                                 first review
#   run_review.sh <n> <head sha> <reason> <reviewed>  re-review; reason is rerequested,
#                                                     changes_requested or dismissed
#   ... --test                                        everything except posting: the
#                                                     review is left in the run's scratch
#                                                     directory (for trying prompt changes)
#   ... --reviewer-model <model>                      overrides the routing below
#
# The reviewer subagent runs on REVIEWER_MODEL_SMALL when the change it reads has
# at most SMALL_PR_MAX_LINES added plus removed lines and touches no RISKY_PATHS,
# and on REVIEWER_MODEL otherwise.
#
# A re-review after a dismissed approval, whose patch is identical to the approved
# one (a rebase), is approved again here, without a Claude run.
#
# The facts a review needs (PR metadata, checkout, earlier review, patch
# comparison) are gathered here with plain gh and git, so the model spends no
# tool calls on them. The run itself starts from about 10K tokens of context
# (claude_lean.sh) and ends when the review is posted.
#
# Prints one line and exits 0 only for the first:
#   POSTED <key> <approve|request-changes|comment> <url>
#   NOT_POSTED <key> <why>        the run decided not to post (or --test)
#   FAILED <key> <why>            the run broke; poll.sh tries again later
#   BUSY <key>                    another run is reviewing it right now
# Everything a run did is kept in state/runs/<n>-<time>/.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config || exit 2

test_mode=0
reviewer_model=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --test) test_mode=1 ;;
    --reviewer-model) reviewer_model="$2"; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
number="${args[0]}"
head_arg="${args[1]}"
reason="${args[2]}"
reviewed="${args[3]:-unknown}"
usage="usage: run_review.sh <n> [<head sha> <reason> <reviewed sha>] [--test]"
case "$number" in '' | *[!0-9]*) echo "$usage" >&2; exit 2 ;; esac
case "$head_arg" in *[!0-9a-f]*) echo "not a commit sha: $head_arg" >&2; exit 2 ;; esac
case "$reason" in '' | rerequested | changes_requested | dismissed) ;; *) echo "unknown reason: $reason" >&2; exit 2 ;; esac
if [ -n "$head_arg" ] && [ -z "$reason" ]; then echo "$usage" >&2; exit 2; fi

key="$number"
[ -n "$head_arg" ] && key="$number@$head_arg"
[ "$test_mode" -eq 1 ] && key="test-$key"

# Paths as Windows tools and prompts expect them (C:/...), where cygpath exists.
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

worktree="$LOCAL_CHECKOUT/.claude/worktrees/review-$number"
cleanup() {
  git -C "$LOCAL_CHECKOUT" worktree remove --force "$worktree" >/dev/null 2>&1
  release_run_lock "$key"
}
fail() {
  log "run $key failed: $*"
  echo "FAILED $key $*"
  exit 1
}

# My approval was dismissed by commits that changed nothing in the patch (a rebase
# or a squash): approve again with a fixed note, at no token cost. Only when the
# dismissed review was an approval; a dismissed change request needs a review.
reapprove_unchanged() {
  local review_id dismissed_state body_file="$scratch/review.md" link
  review_id=$(gh api "repos/$REPO/pulls/$number/reviews?per_page=100" --paginate \
    --jq ".[] | select(.user.login as \$l | $(json_array "$MY_LOGINS") | index(\$l)) | select(.state != \"COMMENTED\") | .id" \
    2>>"$LOG" | tail -1)
  [ -n "$review_id" ] || return 0
  dismissed_state=$(gh api "repos/$REPO/issues/$number/timeline?per_page=100" --paginate \
    --jq ".[] | select(.event == \"review_dismissed\" and .dismissed_review.review_id == $review_id) | .dismissed_review.state" \
    2>>"$LOG" | tail -1)
  [ "$dismissed_state" = "approved" ] || return 0
  cat >"$body_file" <<BODY
## Automated re-review

New commits dismissed my approval of \`${reviewed:0:7}\`. The PR's patch at \`${pr_head:0:7}\` adds and removes exactly the same lines as the patch I approved; only the base or the commit history changed. No review was run, and the earlier review stands.

**Verdict: ready to merge**, as before.
BODY
  if [ "$test_mode" -eq 1 ]; then
    echo "NOT_POSTED $key would approve again: unchanged patch (test run)"
    exit 1
  fi
  gh pr review "$number" --repo "$REPO" --approve --body-file "$body_file" >>"$LOG" 2>&1 ||
    fail "could not post the re-approval"
  link=$(gh api "repos/$REPO/pulls/$number/reviews?per_page=100" --paginate \
    --jq ".[] | select(.user.login == \"$REVIEW_AS\") | .html_url" 2>>"$LOG" | tail -1)
  echo "$(date -u +%FT%TZ) $key cost=\$0.00 session=- RESULT posted approve $link unchanged patch, no Claude run" >>"$REVIEWS_LOG"
  log "run $key: approved again, unchanged patch"
  echo "POSTED $key approve $link"
  exit 0
}

take_run_lock "$key" || { echo "BUSY $key"; exit 1; }
trap cleanup EXIT
attempt="test"
[ "$test_mode" -eq 0 ] && attempt=$(count_attempt "$key")
started_at=$(date -u +%FT%TZ)

run_dir="$RUNS_DIR/$number-$(date -u +%Y%m%dT%H%M%SZ)"
scratch="$run_dir/scratch"
mkdir -p "$scratch" || fail "cannot create $scratch"
log "run $key started (attempt $attempt) in $run_dir"

# --- The PR ---------------------------------------------------------------------
gh pr view "$number" --repo "$REPO" \
  --json url,title,body,author,state,isDraft,headRefOid,additions,deletions,changedFiles,files,reviews \
  >"$scratch/pr.json" 2>>"$LOG" || fail "gh pr view failed"

# Free text (title, description, earlier review) goes to files; only plain tokens
# come back to the shell.
facts=$(SCRATCH="$(winpath "$scratch")" MY="$MY_LOGINS" node "$SCRIPTS/pr_facts.js") || fail "cannot read the PR facts"
read -r url author state is_draft pr_head additions deletions changed_files \
  earlier_state earlier_commit my_verdicts <<<"$facts"
[ -n "$pr_head" ] || fail "could not read the PR"

if [ -n "$head_arg" ] && [ "$pr_head" != "$head_arg" ]; then
  log "run $key: head moved to $pr_head"
  echo "NOT_POSTED $key head moved to ${pr_head:0:7}; the next poll picks it up"
  exit 1
fi
if [ -z "$head_arg" ] && [ "$test_mode" -eq 0 ]; then
  request_reviewer "$number" "$REVIEW_AS" >>"$LOG" 2>&1 || log "could not request $REVIEW_AS on #$number"
fi

# --- Checkout -------------------------------------------------------------------
cd "$LOCAL_CHECKOUT" || fail "no checkout at $LOCAL_CHECKOUT"
git_fetch origin "$BASE_BRANCH" "+pull/$number/head:refs/remotes/origin/pr-$number" || fail "git fetch failed"
git worktree remove --force "$worktree" >/dev/null 2>&1
rm -rf "$worktree"
git worktree prune
git worktree add -q --detach "$worktree" "$pr_head" 2>>"$LOG" || fail "git worktree add failed"
base=$(git merge-base "origin/$BASE_BRANCH" "$pr_head") || fail "no merge base with $BASE_BRANCH"

# --- What the prompts need ------------------------------------------------------
export FILL_PR="$number" FILL_REPO="$REPO" FILL_URL="$url" FILL_AUTHOR="$author" \
  FILL_STATE="$state" FILL_DRAFT="$is_draft" FILL_HEAD="$pr_head" FILL_BASE="$base" \
  FILL_REVIEW_AS="$REVIEW_AS" \
  FILL_SIZE="$changed_files files, +$additions -$deletions"
FILL_WORKTREE="$(winpath "$worktree")"
FILL_SCRATCH="$(winpath "$scratch")"
FILL_SKIP_KEYWORDS="$(skip_keywords_json)"
FILLFILE_TITLE="$(winpath "$scratch/title.txt")"
FILLFILE_PROJECT_CONTEXT="$(winpath "$ROOT/prompts/project-context.md")"
FILL_REQUIREMENTS="The PR description is in \`$FILL_SCRATCH/description.md\`. Read it first."
FILL_QUESTIONS="Read them from \`$FILL_SCRATCH/questions.md\` before the diff."
FILL_MODE=""
if [ "$test_mode" -eq 1 ]; then
  FILL_MODE="**TEST RUN.** Do every step except posting: do not run \`gh pr review\`, \`gh pr comment\` or anything else that writes to GitHub. Write the body to \`review.md\` as usual, and end with \`RESULT not-posted <the verdict you would post> - test run\`."
fi
export FILL_WORKTREE FILL_SCRATCH FILL_SKIP_KEYWORDS FILLFILE_TITLE FILLFILE_PROJECT_CONTEXT \
  FILL_REQUIREMENTS FILL_QUESTIONS FILL_MODE

template="$ROOT/prompts/run-review.md"
range_base="$base"
if [ -n "$head_arg" ]; then
  template="$ROOT/prompts/run-rereview.md"
  [ "$reviewed" = "unknown" ] && reviewed="$earlier_commit"
  case "$reason" in
    rerequested) FILL_REASON_TEXT="my review was requested again" ;;
    changes_requested) FILL_REASON_TEXT="I requested changes and new commits arrived" ;;
    dismissed) FILL_REASON_TEXT="new commits dismissed my approval" ;;
  esac
  since=$(cat "$scratch/earlier-review-at.txt")
  {
    echo "# PR conversation since my last review ($since)"
    gh api "repos/$REPO/issues/$number/comments?since=$since&per_page=100" \
      --jq '.[] | "\n## \(.user.login) at \(.created_at)\n\(.body[0:3000])"'
    echo
    echo "# Review-thread comments since then"
    gh api "repos/$REPO/pulls/$number/comments?since=$since&per_page=100" \
      --jq '.[] | "\n## \(.user.login) at \(.created_at) on \(.path):\(.line // .original_line)\n\(.body[0:3000])"'
  } >"$scratch/conversation.md" 2>>"$LOG"
  bash "$SCRIPTS/compare_patch.sh" "$number" "$reviewed" >"$scratch/compare.txt" 2>>"$LOG"
  if [ "$reviewed" != "unknown" ] && git merge-base --is-ancestor "$reviewed" "$pr_head" 2>/dev/null; then
    range_base="$reviewed"
    FILL_RANGE_NOTE="the commits since my review"
  else
    FILL_RANGE_NOTE="the whole PR, because the branch was rebased or force-pushed since my review"
  fi
  FILL_COMPARE_VERDICT="$(head -1 "$scratch/compare.txt")"
  FILL_RANGE_SIZE="$(git diff --shortstat "$range_base" "$pr_head" | sed 's/^ *//')"
  if [ "$reason" = "dismissed" ] && [[ "$FILL_COMPARE_VERDICT" == PATCH_IDENTICAL* ]]; then
    reapprove_unchanged
  fi
  export FILL_REASON_TEXT FILL_RANGE_NOTE FILL_COMPARE_VERDICT FILL_RANGE_SIZE \
    FILL_REVIEWED="$reviewed" FILL_EARLIER_STATE="$earlier_state" \
    FILL_RANGE_BASE="$range_base" FILL_ROUND="$my_verdicts"
fi

# --- Which model reviews --------------------------------------------------------
# Size and paths of what the reviewer reads: the whole PR, or the range since my
# review for a re-review.
range_lines=$(git diff --numstat "$range_base" "$pr_head" | awk '{ n += $1 + $2 } END { print n + 0 }')
risky=$(git diff --name-only "$range_base" "$pr_head" | grep -E -m1 "${RISKY_PATHS:-^$}")
if [ -z "$reviewer_model" ]; then
  reviewer_model="$REVIEWER_MODEL"
  if [ -n "${REVIEWER_MODEL_SMALL:-}" ] && [ "$range_lines" -le "${SMALL_PR_MAX_LINES:-0}" ] && [ -z "$risky" ]; then
    reviewer_model="$REVIEWER_MODEL_SMALL"
  fi
fi
export FILL_REVIEWER_MODEL="$reviewer_model"
log "run $key: reviewer $reviewer_model ($range_lines lines${risky:+, touches $risky})"

# The reviewer reads the range the orchestrator asks it to.
FILL_BASE="$range_base" node "$SCRIPTS/fill_template.js" \
  "$(winpath "$ROOT/prompts/reviewer.md")" "$(winpath "$scratch/reviewer-prompt.md")" ||
  fail "cannot fill the reviewer prompt"
node "$SCRIPTS/fill_template.js" "$(winpath "$template")" "$(winpath "$run_dir/prompt.md")" ||
  fail "cannot fill the prompt"

# --- The run --------------------------------------------------------------------
# The run may write only in its own directory; the checkout is added for reading.
timeout "${RUN_TIMEOUT_MINUTES}m" bash "$SCRIPTS/claude_lean.sh" --model "$ORCHESTRATOR_MODEL" \
  --add-dir "$(winpath "$run_dir")" --add-dir "$(winpath "$worktree")" \
  --output-format json --max-budget-usd "$MAX_RUN_USD" \
  <"$run_dir/prompt.md" >"$run_dir/result.json" 2>"$run_dir/stderr.txt"
exit_code=$?

summary=$(RESULT_JSON="$(winpath "$run_dir/result.json")" RESULT_TXT="$(winpath "$run_dir/result.txt")" \
  node "$SCRIPTS/run_result.js")
read -r cost session subtype <<<"$summary"
result_line=$(grep -m1 '^RESULT ' "$run_dir/result.txt" | tr -d '\r')
echo "$(date -u +%FT%TZ) $key cost=\$$cost session=$session ${result_line:-no RESULT line, exit $exit_code $subtype}" >>"$REVIEWS_LOG"
log "run $key ended: exit $exit_code, $subtype, \$$cost"

read -r _ outcome verdict link why <<<"$result_line"
case "$outcome" in
  posted | commented)
    # Trust GitHub, not the run's own account of it.
    latest=$(gh api "repos/$REPO/issues/$number/timeline?per_page=100" --paginate \
      --jq ".[] | select(((.user // .actor // {}).login) == \"$REVIEW_AS\") | (.submitted_at // .created_at)" \
      2>>"$LOG" | sort | tail -1)
    if [[ "$latest" > "$started_at" || "$latest" == "$started_at" ]]; then
      echo "POSTED $key $verdict $link"
      exit 0
    fi
    fail "the run says it posted, but GitHub has nothing from $REVIEW_AS since $started_at"
    ;;
  not-posted)
    echo "NOT_POSTED $key ${why:-$verdict}"
    exit 1
    ;;
  *)
    fail "no result (exit $exit_code, $subtype, \$$cost), see $run_dir"
    ;;
esac
