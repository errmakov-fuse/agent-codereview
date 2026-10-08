#!/usr/bin/env bash
# Shared by watch_prs.sh and watchdog.sh: loads config.env and classifies open PRs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${AGENT_CODEREVIEW_CONFIG:-$ROOT/config.env}"
STATE_DIR="${AGENT_CODEREVIEW_STATE:-$ROOT/state}"
HANDLED="$STATE_DIR/handled_prs.txt"
HEARTBEAT="$STATE_DIR/heartbeat"
LOG="$STATE_DIR/watch_prs.log"
MAX_OPEN_PRS=100

load_config() {
  if [ ! -f "$CONFIG" ]; then
    echo "config not found: $CONFIG" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$CONFIG"
  local name
  for name in REPO REVIEW_AS MY_LOGINS WATCHED_AUTHORS MY_PR_REVIEWER POLL_SECONDS HEARTBEAT_MAX_AGE_SECONDS; do
    if [ -z "${!name}" ]; then
      echo "config value missing: $name" >&2
      return 1
    fi
  done
  mkdir -p "$STATE_DIR" && touch "$HANDLED" "$LOG"
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

# Prints one line per open PR that needs action, skipping drafts:
#   MINE <n>    my PR with no reviewer requested and no review from anyone else
#   THEIRS <n>  a watched author's PR that I have not reviewed
# Git Bash has no jq, so the filtering runs inside gh's own --jq.
classify_open_prs() {
  local me watched
  me=$(json_array "$MY_LOGINS") || return 1
  watched=$(json_array "$WATCHED_AUTHORS") || return 1
  gh pr list --repo "$REPO" --state open --limit "$MAX_OPEN_PRS" \
    --json number,author,isDraft,reviewRequests,reviews \
    --jq "$me as \$me | $watched as \$watched
      | .[] | select(.isDraft | not)
      | .author.login as \$author
      | [.reviews[] | .author.login // \"\"] as \$reviewers
      | if (\$me | any(. == \$author)) then
          (if (.reviewRequests | length) == 0 and ((\$reviewers - \$me) | length) == 0
           then \"MINE \(.number)\" else empty end)
        elif (\$watched | any(. == \$author)) then
          (if ((\$reviewers - (\$reviewers - \$me)) | length) == 0
           then \"THEIRS \(.number)\" else empty end)
        else empty end"
}

is_handled() {
  grep -qx "$1" "$HANDLED"
}

# The REST endpoint, because `gh pr edit --add-reviewer` fails on repositories
# that still have classic Projects ("Projects (classic) is being deprecated").
request_reviewer() {
  gh api -X POST "repos/$REPO/pulls/$1/requested_reviewers" -f "reviewers[]=$2" --jq '.number'
}
