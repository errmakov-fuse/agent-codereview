#!/usr/bin/env bash
# Runs `claude -p` with the smallest context that can still review a PR.
#
#   claude_lean.sh [any other claude flags, e.g. --model sonnet] < prompt.txt
#
# A normal session carries about 51K tokens before it reads a word of the PR:
# the user's global rules, the watched repository's CLAUDE.md and memory index,
# every installed plugin's hooks and skills, MCP servers and some 27 tools. Each
# tool call re-sends all of it, for the orchestrator and for every reviewer
# subagent. With these flags a run starts at about 10K and a subagent at 8K.
#
#   cwd = this repository    the watched repo's CLAUDE.md and memory are not loaded
#   --setting-sources        user settings (plugins, hooks, model) are not loaded
#   lean-settings.json       global rules and any CLAUDE.md are excluded; tools are
#                            allowed without prompts, everything else is refused
#   --tools                  only the tools a review needs
#   --strict-mcp-config, --no-chrome, --disable-slash-commands
#                            no MCP servers, browser or skills
#   --name                   REVIEW_SESSION_NAME, so the PR update watcher
#                            never takes a run for a session to tell about a PR
#
# The review gets its project knowledge from prompts/project-context.md instead.
# Runs headless, so it needs no workspace trust. It signs in with the token in
# CLAUDE_TOKEN_FILE when config.env names one, else with the normal login, which
# reaches a time limit that an unattended run cannot renew.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config || exit 2

if [ -n "${CLAUDE_TOKEN_FILE:-}" ]; then
  if [ -r "$CLAUDE_TOKEN_FILE" ] && token=$(tr -d '\r\n' <"$CLAUDE_TOKEN_FILE") && [ -n "$token" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$token"
  else
    log "CLAUDE_TOKEN_FILE $CLAUDE_TOKEN_FILE is missing or empty; this run uses the normal login"
  fi
fi

LEAN_TOOLS="Bash,Read,Grep,Glob,Agent,Write"

cd "$ROOT" || exit 2
exec claude -p --name "$REVIEW_SESSION_NAME" \
  --settings "$ROOT/claude/lean-settings.json" \
  --setting-sources project,local \
  --strict-mcp-config --no-chrome --disable-slash-commands \
  --tools "$LEAN_TOOLS" \
  --add-dir "$LOCAL_CHECKOUT" \
  "$@"
