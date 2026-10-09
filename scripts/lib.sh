#!/usr/bin/env bash
# Shared by watch_prs.sh and watchdog.sh: loads config.env and classifies open PRs.

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
CONFIG="${AGENT_CODEREVIEW_CONFIG:-$ROOT/config.env}"
STATE_DIR="${AGENT_CODEREVIEW_STATE:-$ROOT/state}"
HANDLED="$STATE_DIR/handled_prs.txt"
HEARTBEAT="$STATE_DIR/heartbeat"
LOG="$STATE_DIR/watch_prs.log"
FIRST_SEEN="$STATE_DIR/rereview_first_seen.txt"
MAX_OPEN_PRS=100

load_config() {
  if [ ! -f "$CONFIG" ]; then
    echo "config not found: $CONFIG" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$CONFIG"
  local name
  for name in REPO REVIEW_AS MY_LOGINS WATCHED_AUTHORS MY_PR_REVIEWER POLL_SECONDS \
    HEARTBEAT_MAX_AGE_SECONDS REREVIEW_SETTLE_SECONDS REREVIEW_DISMISSED_APPROVALS REVIEW_DRAFTS; do
    if [ -z "${!name}" ]; then
      echo "config value missing: $name" >&2
      return 1
    fi
  done
  mkdir -p "$STATE_DIR" && touch "$HANDLED" "$LOG" "$FIRST_SEEN"
}

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
  me=$(json_array "$MY_LOGINS") || return 1
  watched=$(json_array "$WATCHED_AUTHORS") || return 1
  skip=$(skip_keywords_json) || return 1
  drafts=$(json_bool "$REVIEW_DRAFTS")
  dismissed=$(json_bool "$REREVIEW_DISMISSED_APPROVALS")
  gh pr list --repo "$REPO" --state open --limit "$MAX_OPEN_PRS" \
    --json number,title,author,isDraft,headRefOid,reviewRequests,reviews \
    --jq "$me as \$me | $watched as \$watched | $skip as \$skip_keywords
      | $drafts as \$review_drafts | $dismissed as \$rereview_dismissed
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
