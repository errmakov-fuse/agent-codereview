#!/usr/bin/env bash
# Tells whether a PR still contains what was reviewed, after a rebase, squash or
# force-push, so an unchanged PR can be approved again without a full re-review.
#
#   compare_patch.sh <pr number> <reviewed commit sha>
#
# It compares the PR's whole patch (merge base to tip) at the reviewed commit
# with the same at the current head, as two bags of added and removed lines.
# Context lines and line numbers are ignored, so moving the branch onto a newer
# base does not count as a change. Run it from anywhere; it works in LOCAL_CHECKOUT
# and only fetches.
#
# First line of output:
#   PATCH_IDENTICAL  the same lines are added and removed
#   PATCH_SUBSET     the new patch only lost lines (for example, commits it was
#                    stacked on were merged separately)
#   PATCH_CHANGED    the new patch has lines the reviewed one did not
#   PATCH_UNKNOWN    the reviewed commit can no longer be fetched
# followed by the file and line counts, and the lines that differ ("<" only in
# the reviewed patch, ">" only in the new one), up to MAX_LINES_SHOWN.
#
# Limit: a block moved to another place, unchanged, does not show up. Use the
# result to decide how much to read, not as proof on its own.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAX_LINES_SHOWN=60

if [ $# -ne 2 ]; then
  echo "usage: compare_patch.sh <pr number> <reviewed commit sha>" >&2
  exit 2
fi
number="$1"
reviewed="$2"

load_config || exit 2
if [ -z "$LOCAL_CHECKOUT" ] || [ -z "$BASE_BRANCH" ]; then
  echo "config value missing: LOCAL_CHECKOUT or BASE_BRANCH" >&2
  exit 2
fi
cd "$LOCAL_CHECKOUT" || exit 2

git_fetch origin "$BASE_BRANCH" "+pull/$number/head:refs/remotes/origin/pr-$number" || exit 2
git fetch -q origin "$reviewed" 2>/dev/null
head=$(git rev-parse "origin/pr-$number")
if ! git cat-file -e "$reviewed^{commit}" 2>/dev/null; then
  echo "PATCH_UNKNOWN reviewed commit $reviewed is not available"
  exit 0
fi

# The added and removed lines of base..tip, sorted, without file headers.
patch_lines() {
  local tip="$1" base
  base=$(git merge-base "origin/$BASE_BRANCH" "$tip") || return 1
  git diff -U0 "$base" "$tip" | grep '^[+-]' | grep -v -e '^+++ ' -e '^--- ' | sort
}
file_count() {
  git diff --name-only "$(git merge-base "origin/$BASE_BRANCH" "$1")" "$1" | wc -l | tr -d ' '
}

before=$(patch_lines "$reviewed") || exit 2
after=$(patch_lines "$head") || exit 2
difference=$(diff <(echo "$before") <(echo "$after") | grep '^[<>]')
only_before=$(echo "$difference" | grep -c '^<')
only_after=$(echo "$difference" | grep -c '^>')

if [ "$only_before" -eq 0 ] && [ "$only_after" -eq 0 ]; then
  verdict=PATCH_IDENTICAL
elif [ "$only_after" -eq 0 ]; then
  verdict=PATCH_SUBSET
else
  verdict=PATCH_CHANGED
fi

echo "$verdict #$number reviewed=${reviewed:0:7} head=${head:0:7}"
echo "files: $(file_count "$reviewed") -> $(file_count "$head")"
echo "changed lines: $(echo "$before" | grep -c .) -> $(echo "$after" | grep -c .)"
echo "only in the reviewed patch: $only_before, only in the new patch: $only_after"
if [ -n "$difference" ]; then
  # New lines first: they are what has not been reviewed.
  { echo "$difference" | grep '^>'; echo "$difference" | grep '^<'; } | head -n "$MAX_LINES_SHOWN" | cut -c1-200
  shown=$((only_before + only_after))
  [ "$shown" -gt "$MAX_LINES_SHOWN" ] && echo "... $((shown - MAX_LINES_SHOWN)) more lines not shown"
fi
exit 0
