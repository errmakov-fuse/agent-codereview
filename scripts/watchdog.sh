#!/usr/bin/env bash
# One call tells the agent whether the watcher is running and what it missed.
#
#   ALIVE heartbeat <n>s ago   nothing to do
#   DEAD heartbeat <n>s ago    followed by "handled: ..." and one line per open PR
#                              that still needs action; the agent handles those
#                              and restarts watch_prs.sh:
#                                MINE <n>
#                                THEIRS <n>
#                                REREVIEW <n>@<head sha> <reason>

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config || exit 2

now=$(date +%s)
beat=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
age=$((now - beat))

if [ "$beat" != "0" ] && [ "$age" -le "$HEARTBEAT_MAX_AGE_SECONDS" ]; then
  echo "ALIVE heartbeat ${age}s ago"
  exit 0
fi

if [ "$beat" = "0" ]; then
  # watch_prs.sh resets the heartbeat when it exits, so this is a watcher that
  # stopped (often to hand over a PR whose exit never reached the session).
  echo "DEAD watcher exited"
else
  echo "DEAD heartbeat ${age}s ago"
fi
echo "handled: $(tr '\n' ' ' <"$HANDLED")"
if ! open=$(classify_open_prs); then
  echo "LIST_FAILED could not list open PRs"
  exit 1
fi
while read -r kind number head reason _; do
  case "$kind" in
    MINE) is_handled "own-$number" || echo "MINE $number" ;;
    THEIRS) is_handled "$number" || echo "THEIRS $number" ;;
    REREVIEW)
      is_handled "$number@$head" && continue
      rereview_ready "$number@$head" "$reason" && echo "REREVIEW $number@$head $reason"
      ;;
  esac
done <<<"$open"
