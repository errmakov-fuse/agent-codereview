#!/usr/bin/env bash
# Checks the defaults load_config gives the PR update settings when config.env
# does not set them, and that a non-numeric number is refused.
#
# Works on a temp copy of config.env and a temp state dir, so it touches nothing real.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TESTS/../scripts/lib.sh"
CONFIG_SRC="$TESTS/../config.env"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# config.env without any PR_UPDATE_* line: every setting must come from the defaults.
grep -v '^PR_UPDATE_' "$CONFIG_SRC" >"$TMP/defaults.env"
# The same, plus a number that is not one.
{ cat "$TMP/defaults.env"; echo 'PR_UPDATE_MAX_PER_PR_PER_DAY=abc'; } >"$TMP/bad.env"
# The same, with extra logins to ignore: MY_LOGINS must stay in the list.
{ cat "$TMP/defaults.env"; echo 'PR_UPDATE_IGNORE_LOGINS="renovate[bot] ci-bot"'; } >"$TMP/ignore.env"

# Runs load_config in a subshell against the given config and state dir, then
# prints what it set. The sourced config is the only place MY_LOGINS comes from.
loaded() {
  (
    AGENT_CODEREVIEW_CONFIG="$1" AGENT_CODEREVIEW_STATE="$2"
    export AGENT_CODEREVIEW_CONFIG AGENT_CODEREVIEW_STATE
    # shellcheck source=/dev/null
    . "$LIB"
    load_config || { echo "load_config returned $?"; exit 1; }
    echo "PR_UPDATE_ENABLED = $PR_UPDATE_ENABLED"
    echo "PR_UPDATE_IGNORE_LOGINS = \"$PR_UPDATE_IGNORE_LOGINS\""
    echo "PR_UPDATE_MAX_PER_PR_PER_DAY = $PR_UPDATE_MAX_PER_PR_PER_DAY"
    echo "PR_UPDATE_MAX_RESUMES_PER_PASS = $PR_UPDATE_MAX_RESUMES_PER_PASS"
    echo "PR_UPDATE_RESUME_RETIRED = $PR_UPDATE_RESUME_RETIRED"
    [ -d "$PR_UPDATES_DIR" ] && echo "-d \"\$PR_UPDATES_DIR\"" || echo "no PR_UPDATES_DIR"
  ) 2>&1
}

failed=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
    return
  fi
  failed=1
  echo "FAIL $name"
  echo "--- expected"
  echo "$expected"
  echo "--- actual"
  echo "$actual"
}

# The expected ignore list follows whatever MY_LOGINS the config holds.
my_logins="$(. "$TMP/defaults.env" && echo "$MY_LOGINS")"

check "settings missing from config.env get their defaults" \
  "PR_UPDATE_ENABLED = true
PR_UPDATE_IGNORE_LOGINS = \"$my_logins dependabot[bot]\"
PR_UPDATE_MAX_PER_PR_PER_DAY = 6
PR_UPDATE_MAX_RESUMES_PER_PASS = 2
PR_UPDATE_RESUME_RETIRED = true
-d \"\$PR_UPDATES_DIR\"" "$(loaded "$TMP/defaults.env" "$TMP/state1")"

# The shipped config sets its own extra ignored logins; every other setting it
# ships at the default value.
shipped_ignore="$(. "$CONFIG_SRC" && echo "${PR_UPDATE_IGNORE_LOGINS:-dependabot[bot]}")"
check "the settings as shipped in config.env load as the defaults do, plus its ignored logins" \
  "$(loaded "$TMP/defaults.env" "$TMP/state2" | sed "s/^PR_UPDATE_IGNORE_LOGINS = .*/PR_UPDATE_IGNORE_LOGINS = \"$my_logins $shipped_ignore\"/")" \
  "$(loaded "$CONFIG_SRC" "$TMP/state3")"

check "extra ignored logins are added to MY_LOGINS, not put in their place" \
  "PR_UPDATE_IGNORE_LOGINS = \"$my_logins renovate[bot] ci-bot\"" \
  "$(loaded "$TMP/ignore.env" "$TMP/state5" | grep "^PR_UPDATE_IGNORE_LOGINS")"

check "a non-numeric PR_UPDATE_MAX_PER_PR_PER_DAY is refused" \
  "PR_UPDATE_MAX_PER_PR_PER_DAY must be a number
load_config returned 1" "$(loaded "$TMP/bad.env" "$TMP/state4")"

exit "$failed"
