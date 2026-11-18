#!/usr/bin/env bash
# Checks what scripts/run_result.js makes of the JSON a `claude -p` run printed:
# "cost session subtype", with subtype auth-failed when the run could not sign in,
# so run_review.sh does not count that against the PR.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT="$TESTS/../scripts/run_result.js"
FIXTURES="$TESTS/fixtures/run_result"
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

summary() {
  RESULT_JSON="$(winpath "$1")" RESULT_TXT="$(winpath "$TMP/result.txt")" node "$RESULT"
}

check "a posted run keeps its cost, session and subtype" \
  "$(node -e 'const r=require(process.argv[1]);console.log(r.total_cost_usd.toFixed(2),r.session_id,r.subtype)' "$(winpath "$FIXTURES/posted.json")")" \
  "$(summary "$FIXTURES/posted.json")"
check "a posted run's final message goes to result.txt" \
  "RESULT posted approve https://github.com/Org/repo/pull/7#pullrequestreview-1 -" \
  "$(head -1 "$TMP/result.txt" | tr -d '\r')"

check "a run whose login expired is auth-failed (real result of 2026-11-17)" \
  "0.00 acbca38e-6cf6-4242-a228-f396fd812813 auth-failed" \
  "$(summary "$FIXTURES/auth_failed.json")"

echo '{"is_error":true,"subtype":"success","total_cost_usd":0,"session_id":"s1","result":"Invalid API key · Please run /login"}' >"$TMP/key.json"
check "an invalid API key is auth-failed" "0.00 s1 auth-failed" "$(summary "$TMP/key.json")"

echo '{"is_error":false,"subtype":"success","total_cost_usd":1.2,"session_id":"s2","result":"The PR asks to run claude auth login in its README.\nRESULT posted approve u -"}' >"$TMP/words.json"
check "a successful run that only mentions logging in is not auth-failed" "1.20 s2 success" "$(summary "$TMP/words.json")"

echo '{"is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":25,"session_id":"s3","result":""}' >"$TMP/budget.json"
check "another error keeps its subtype" "25.00 s3 error_max_budget_usd" "$(summary "$TMP/budget.json")"

: >"$TMP/empty.json"
check "a run that printed nothing is no-result" "0.00 - no-result" "$(summary "$TMP/empty.json")"

exit $failed
