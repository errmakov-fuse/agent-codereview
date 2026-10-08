#!/usr/bin/env bash
# One call tells the agent whether the watcher is running and what it missed.
#
#   ALIVE heartbeat <n>s ago   nothing to do
#   DEAD heartbeat <n>s ago    followed by "handled: ..." and one MINE/THEIRS line
#                              per open PR that still needs action; the agent
#                              handles those and restarts watch_prs.sh

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config || exit 2

now=$(date +%s)
beat=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
age=$((now - beat))

if [ "$age" -le "$HEARTBEAT_MAX_AGE_SECONDS" ]; then
  echo "ALIVE heartbeat ${age}s ago"
  exit 0
fi

echo "DEAD heartbeat ${age}s ago"
echo "handled: $(tr '\n' ' ' <"$HANDLED")"
if ! open=$(classify_open_prs); then
  echo "LIST_FAILED could not list open PRs"
  exit 1
fi
while read -r kind number; do
  case "$kind" in
    MINE) is_handled "own-$number" || echo "MINE $number" ;;
    THEIRS) is_handled "$number" || echo "THEIRS $number" ;;
  esac
done <<<"$open"
