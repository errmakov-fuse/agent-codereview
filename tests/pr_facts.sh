#!/usr/bin/env bash
# Checks what scripts/pr_facts.js writes for run_review.sh: the plain token line
# and checks.md, the CI checks on the head as the review run sees them.
#
# Works on temp copies of the fixtures, so it touches nothing real.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTS="$TESTS/../scripts/pr_facts.js"
FIXTURES="$TESTS/fixtures/pr_facts"
winpath() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
    return
  fi
  failed=1
  echo "FAIL $name"
  echo "--- expected"; printf '%s\n' "$expected"
  echo "--- actual"; printf '%s\n' "$actual"
}

# Runs pr_facts.js in a fresh scratch dir holding the fixture pr.json and, when
# given, the file as checks.json (gh pr checks --json); prints the token line.
facts() {
  rm -rf "$TMP/scratch" && mkdir "$TMP/scratch" && cp "$FIXTURES/pr.json" "$TMP/scratch/pr.json"
  [ -n "$1" ] && cp "$1" "$TMP/scratch/checks.json"
  SCRATCH="$(winpath "$TMP/scratch")" MY="errmakov-fuse errmakov" node "$FACTS"
}
checks_md() { tr -d '\r' <"$TMP/scratch/checks.md"; }

check "the token line is unchanged" \
  "https://github.com/Org/repo/pull/7 samrent-infuse OPEN false 43f8607ee76ef3e7c3f0ee350bc5800e4d0c12e7 10 2 3 DISMISSED 85b12cc0000000000000000000000000000000000 1" \
  "$(facts "$FIXTURES/checks.json")"

check "checks.md lists the failed checks with what they report and their links, then the running ones" \
  "# CI checks on 43f8607, when this run started

Failed:
- S.Y.S.T.E.M / open the scan report: 1 credential(s) committed by this change. Details: https://scan.example/report?id=1
- Lint & Test. Details: https://github.com/Org/repo/actions/runs/1

Still running:
- E2E Tests
- deploy-preview: Building

Passed or skipped: 2." \
  "$(checks_md)"

echo '[{"bucket":"pass","description":"","link":"x","name":"validate-pair","state":"SUCCESS","workflow":"Q"}]' >"$TMP/green.json"
facts "$TMP/green.json" >/dev/null
check "checks.md says so when nothing failed or is running" \
  "# CI checks on 43f8607, when this run started

No check failed and none is running. Passed or skipped: 1." \
  "$(checks_md)"

: >"$TMP/empty.json"
facts "$TMP/empty.json" >/dev/null
check "checks.md says so when gh reported no checks (empty output)" \
  "# CI checks on 43f8607, when this run started

The head has no checks." \
  "$(checks_md)"

facts "" >/dev/null
check "checks.md says so when there is no checks.json" \
  "# CI checks on 43f8607, when this run started

The head has no checks." \
  "$(checks_md)"

echo 'not json' >"$TMP/bad.json"
check "unreadable checks still give the token line" \
  "https://github.com/Org/repo/pull/7 samrent-infuse OPEN false 43f8607ee76ef3e7c3f0ee350bc5800e4d0c12e7 10 2 3 DISMISSED 85b12cc0000000000000000000000000000000000 1" \
  "$(facts "$TMP/bad.json" 2>/dev/null)"
check "checks.md says so when the checks could not be read" \
  "# CI checks on 43f8607, when this run started

The checks could not be read; run \`gh pr checks\` for them." \
  "$(checks_md)"

exit $failed
