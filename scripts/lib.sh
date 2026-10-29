#!/usr/bin/env bash
# Shared by the scripts: loads config.env, classifies open PRs, and keeps the
# per-review lock and attempt counts.

# A scheduled task starts with a bare PATH; gh and claude live in the user's bin dirs.
PATH="$HOME/bin:$HOME/.local/bin:/c/Program Files/nodejs:$PATH"

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
CONFIG="${AGENT_CODEREVIEW_CONFIG:-$ROOT/config.env}"
STATE_DIR="${AGENT_CODEREVIEW_STATE:-$ROOT/state}"
HANDLED="$STATE_DIR/handled_prs.txt"
LOG="$STATE_DIR/poll.log"
FIRST_SEEN="$STATE_DIR/rereview_first_seen.txt"
ATTEMPTS="$STATE_DIR/attempts.txt"
GAVE_UP="$STATE_DIR/gave_up.txt"
RUNNING_DIR="$STATE_DIR/running"
RUNS_DIR="$STATE_DIR/runs"
REVIEWS_LOG="$STATE_DIR/reviews.log"
CAPPED="$STATE_DIR/capped.txt"
LAST_POLL="$STATE_DIR/last_poll"
PR_UPDATES_DIR="$STATE_DIR/pr_updates"
MAX_OPEN_PRS=100
# The name claude_lean.sh gives every review run, by which the PR update watcher
# knows them and never watches them.
REVIEW_SESSION_NAME=agent-codereview-review

load_config() {
  if [ ! -f "$CONFIG" ]; then
    echo "config not found: $CONFIG" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$CONFIG"
  local name
  for name in REPO BASE_BRANCH LOCAL_CHECKOUT REVIEW_AS MY_LOGINS WATCHED_AUTHORS MY_PR_REVIEWER \
    POLL_SECONDS REREVIEW_SETTLE_SECONDS REREVIEW_DISMISSED_APPROVALS REVIEW_DRAFTS \
    ORCHESTRATOR_MODEL REVIEWER_MODEL MAX_PARALLEL_REVIEWS RUN_TIMEOUT_MINUTES MAX_RUN_USD MAX_ATTEMPTS; do
    if [ -z "${!name}" ]; then
      echo "config value missing: $name" >&2
      return 1
    fi
  done
  # The PR update settings may be left out of config.env.
  : "${PR_UPDATE_ENABLED:=true}"
  # MY_LOGINS are always ignored, whatever the setting holds: a session that
  # comments on its own PR must not be woken by its own words, again and again.
  PR_UPDATE_IGNORE_LOGINS="$MY_LOGINS ${PR_UPDATE_IGNORE_LOGINS:-dependabot[bot]}"
  : "${PR_UPDATE_MAX_PER_PR_PER_DAY:=6}"
  : "${PR_UPDATE_MAX_RESUMES_PER_PASS:=2}"
  : "${PR_UPDATE_RESUME_RETIRED:=true}"
  for name in PR_UPDATE_MAX_PER_PR_PER_DAY PR_UPDATE_MAX_RESUMES_PER_PASS; do
    case "${!name}" in *[!0-9]*) echo "$name must be a number" >&2; return 1 ;; esac
  done
  mkdir -p "$STATE_DIR" "$RUNNING_DIR" "$RUNS_DIR" "$PR_UPDATES_DIR" &&
    touch "$HANDLED" "$LOG" "$FIRST_SEEN" "$ATTEMPTS" "$GAVE_UP" "$REVIEWS_LOG" "$CAPPED"
}

log() {
  echo "$(date -u +%FT%TZ) $*" >>"$LOG"
}

# Paths as Windows tools and prompts expect them (C:/...), where cygpath exists.
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

# "a b" -> ["a","b"]. Logins end up inside a jq filter, so anything that is not a
# plain GitHub login is refused.
json_array() {
  local out="" login
  for login in $1; do
    case "$login" in
      *[!A-Za-z0-9-]*)
        echo "not a GitHub login: $login" >&2
        return 1
        ;;
    esac
    out="$out${out:+,}\"$login\""
  done
  echo "[$out]"
}

# SKIP_TITLE_KEYWORDS -> ["one","two words"]. The keywords end up inside a jq
# filter as string literals, so the two characters that could end one are refused.
skip_keywords_json() {
  local out="" keyword
  for keyword in "${SKIP_TITLE_KEYWORDS[@]}"; do
    [ -z "$keyword" ] && continue
    case "$keyword" in
      *\"* | *\\*)
        echo "skip keyword may not contain \" or \\: $keyword" >&2
        return 1
        ;;
    esac
    out="$out${out:+,}\"$keyword\""
  done
  echo "[$out]"
}

# An on/off setting as a jq boolean: 1, true, yes or on (any case) is on.
json_bool() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) echo true ;;
    *) echo false ;;
  esac
}

# Prints the MINE / THEIRS / REREVIEW lines described in classify.jq.
# Git Bash has no jq, so the filtering runs inside gh's own --jq.
classify_open_prs() {
  local me watched skip drafts dismissed
  case "${MAX_CHANGE_ROUNDS:-0}" in *[!0-9]*) echo "MAX_CHANGE_ROUNDS must be a number" >&2; return 1 ;; esac
  me=$(json_array "$MY_LOGINS") || return 1
  watched=$(json_array "$WATCHED_AUTHORS") || return 1
  skip=$(skip_keywords_json) || return 1
  drafts=$(json_bool "$REVIEW_DRAFTS")
  dismissed=$(json_bool "$REREVIEW_DISMISSED_APPROVALS")
  gh pr list --repo "$REPO" --state open --limit "$MAX_OPEN_PRS" \
    --json number,title,author,isDraft,headRefOid,reviewRequests,reviews,statusCheckRollup \
    --jq "$me as \$me | $watched as \$watched | $skip as \$skip_keywords
      | $drafts as \$review_drafts | $dismissed as \$rereview_dismissed
      | ${MAX_CHANGE_ROUNDS:-0} as \$max_change_rounds
      | $(cat "$SCRIPTS/classify.jq")"
}

is_handled() {
  grep -qx "$1" "$HANDLED"
}

# A re-review waits until the PR head has stayed the same for
# REREVIEW_SETTLE_SECONDS, so a run of fix-up pushes costs one review, not one
# each. An explicit re-request from the author is taken as "ready" at once.
rereview_ready() {
  local key="$1" reason="$2" now first
  [ "$reason" = "rerequested" ] && return 0
  now=$(date +%s)
  first=$(awk -v key="$key" '$1 == key { print $2; exit }' "$FIRST_SEEN")
  if [ -z "$first" ]; then
    echo "$key $now" >>"$FIRST_SEEN"
    first=$now
  fi
  [ $((now - first)) -ge "$REREVIEW_SETTLE_SECONDS" ]
}

# The REST endpoint, because `gh pr edit --add-reviewer` fails on repositories
# that still have classic Projects ("Projects (classic) is being deprecated").
request_reviewer() {
  gh api -X POST "repos/$REPO/pulls/$1/requested_reviewers" -f "reviewers[]=$2" --jq '.number'
}

# --- Review runs -------------------------------------------------------------
# A review is keyed "<n>" (first review) or "<n>@<head sha>" (re-review at that head).

# True while a live run_review.sh holds the key. A lock whose process is gone
# (killed by the task's time limit, a reboot) does not count.
run_is_live() {
  local pid
  pid=$(cat "$RUNNING_DIR/$1/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

live_run_count() {
  local dir count=0
  for dir in "$RUNNING_DIR"/*/; do
    [ -d "$dir" ] || continue
    run_is_live "$(basename "$dir")" && count=$((count + 1))
  done
  echo "$count"
}

# Takes the lock for a key, or fails if a live run holds it. mkdir is atomic, so
# two polls that pick the same PR at once start one run.
take_run_lock() {
  local dir="$RUNNING_DIR/$1"
  if ! mkdir "$dir" 2>/dev/null; then
    run_is_live "$1" && return 1
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || return 1
  fi
  echo "$$" >"$dir/pid"
}

release_run_lock() {
  rm -rf "${RUNNING_DIR:?}/$1"
}

attempts_of() {
  awk -v key="$1" '$1 == key { n = $2 } END { print n + 0 }' "$ATTEMPTS"
}

count_attempt() {
  local n
  n=$(($(attempts_of "$1") + 1))
  { grep -v "^$1 " "$ATTEMPTS"; echo "$1 $n"; } >"$ATTEMPTS.tmp" && mv "$ATTEMPTS.tmp" "$ATTEMPTS"
  echo "$n"
}

# Parallel runs fetch into the same repository; git's ref locks then make one of
# two simultaneous fetches fail. Try a few times.
git_fetch() {
  local try
  for try in 1 2 3 4; do
    git fetch -q "$@" 2>/dev/null && return 0
    sleep $((try * 5))
  done
  git fetch -q "$@"
}
