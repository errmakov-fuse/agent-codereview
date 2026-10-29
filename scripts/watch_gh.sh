#!/usr/bin/env bash
# The PR update watcher's GitHub reads: the gh calls whose failures it has to
# tell apart, and the Node snippets that read their JSON (Git Bash has no jq).
# Sourced by watch_pr_updates.sh after lib.sh, watch_lib.sh and its $scratch
# dir exist; $scratch/gh_err holds the stderr of the last gh_quiet.

PER_PAGE=100

READ_STDIN='const data = JSON.parse(require("fs").readFileSync(0, "utf8"));'
# An entry without an updatedAt would print "undefined", which compares as newer
# than any time for ever; it is left out, and how many were is the only stderr.
PARSE_PR_LIST="$READ_STDIN"'
const kept = data.filter((pr) => pr && typeof pr.updatedAt === "string" && pr.updatedAt);
if (kept.length < data.length) process.stderr.write(String(data.length - kept.length));
process.stdout.write(kept.map((pr) => pr.number + "\t" + pr.updatedAt + "\n").join(""));'
PARSE_PR_VIEW="$READ_STDIN"'
process.stdout.write((data.state || "") + "\t" + ((data.mergedBy && data.mergedBy.login) || "") + "\n");'
PARSE_CLOSER="$READ_STDIN"'
const closed = data.filter((e) => e && e.event === "closed").pop();
process.stdout.write(((closed && closed.actor && closed.actor.login) || "") + "\n");'

# What gh's stderr says about a repository GitHub would not resolve. It is also
# the answer for a private repository the current gh account cannot see (after
# `gh auth switch`, a lost scope or org access), so it never means "gone".
REPO_UNRESOLVED='Could not resolve to a Repository'
# What gh's stderr says about a PR that does not exist in a repository it can
# read (`gh pr view` on a missing number says the first).
PR_MISSING='could not resolve to a pullrequest|no pull requests? found'

# Runs gh with its stderr kept in $scratch/gh_err, for the caller to judge: an
# unreachable repository is logged once per outage, not on every pass.
gh_quiet() {
  gh "$@" 2>"$scratch/gh_err" </dev/null
}

# gh's stderr from the last gh_quiet, on one line.
gh_why() {
  tr '\n' ' ' <"$scratch/gh_err" | sed 's/ *$//'
}

# Appends gh's stderr from the last gh_quiet to the log, as gh would have.
gh_log_err() {
  cat "$scratch/gh_err" >>"$LOG"
}

# "<n>\t<updatedAt>" for each open PR of a repository. Status 2 when GitHub
# would not resolve the repository, 1 when gh fails otherwise, 4 when the list
# had PRs without an updatedAt: those are left out, so the list is not complete.
# Each such repository goes into $scratch/no_updated_at, logged once a pass.
open_prs_of() {
  local list parsed skipped
  if ! list=$(gh_quiet pr list --repo "$1" --state open --limit "$MAX_OPEN_PRS" --json number,updatedAt); then
    grep -q "$REPO_UNRESOLVED" "$scratch/gh_err" && return 2
    gh_log_err
    return 1
  fi
  gh_log_err
  if ! parsed=$(printf '%s' "$list" | node -e "$PARSE_PR_LIST" 2>"$scratch/parse_err"); then
    cat "$scratch/parse_err" >>"$LOG"
    return 1
  fi
  [ -n "$parsed" ] && printf '%s\n' "$parsed"
  skipped=$(cat "$scratch/parse_err")
  [ -n "$skipped" ] || return 0
  case "$skipped" in
    *[!0-9]*)
      printf '%s\n' "$skipped" >>"$LOG"
      return 0
      ;;
  esac
  printf '%s (%s)\n' "$1" "$skipped" >>"$scratch/no_updated_at"
  return 4
}

# One log line for the repositories whose open list had PRs without an updatedAt.
log_no_updated_at() {
  [ -s "$scratch/no_updated_at" ] || return 0
  log "gh pr list gave open PRs without an updatedAt, left out of this pass (PRs each): $(paste -sd, "$scratch/no_updated_at" | sed 's/,/, /g')"
}

# "<STATE>\t<merged by>" of a PR. Status 3 when GitHub says there is no such PR,
# 2 when it would not resolve the repository, 1 when gh fails otherwise.
pr_state() {
  local view
  if ! view=$(gh_quiet pr view "$2" --repo "$1" --json state,mergedBy); then
    grep -qiE "$PR_MISSING" "$scratch/gh_err" && return 3
    grep -q "$REPO_UNRESOLVED" "$scratch/gh_err" && return 2
    gh_log_err
    return 1
  fi
  gh_log_err
  printf '%s' "$view" | node -e "$PARSE_PR_VIEW" 2>>"$LOG"
}

# Who closed a PR: the actor of its last "closed" timeline event, or nothing.
closer_of() {
  local timeline
  timeline=$(gh api "repos/$1/issues/$2/timeline?per_page=$PER_PAGE" 2>>"$LOG" </dev/null) || return 1
  printf '%s' "$timeline" | node -e "$PARSE_CLOSER" 2>>"$LOG" || echo ""
}
