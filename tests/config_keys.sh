#!/usr/bin/env bash
# Checks that the live config.env sets the same variables as config.env.example:
# the same names, each as many times. A name added to the example but not to the
# live file (or the other way round) is reported by name.
#
#   tests/config_keys.sh [example] [live]   defaults: config.env.example, config.env
#
# Without a live config.env (a fresh clone) there is nothing to compare: it says so
# and passes.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="${1:-$TESTS/../config.env.example}"
LIVE="${2:-$TESTS/../config.env}"

if [ ! -f "$EXAMPLE" ]; then
  echo "FAIL example config not found: $EXAMPLE"
  exit 1
fi
if [ ! -f "$LIVE" ]; then
  echo "skip no live config at $LIVE"
  exit 0
fi

# One line per assignment, comments left out, sorted with repeats kept.
names() {
  tr -d '\r' <"$1" | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort
}

example_names="$(names "$EXAMPLE")"
live_names="$(names "$LIVE")"
example_count="$(printf '%s\n' "$example_names" | grep -c .)"
live_count="$(printf '%s\n' "$live_names" | grep -c .)"

if [ "$example_names" = "$live_names" ]; then
  echo "ok   config.env sets the same $live_count variables as config.env.example"
  exit 0
fi

echo "FAIL config.env and config.env.example set different variables ($live_count vs $example_count)"
# comm on the sorted lists with repeats: a name set twice in one file and once in the
# other shows up once on that side.
missing="$(comm -23 <(printf '%s\n' "$example_names") <(printf '%s\n' "$live_names"))"
extra="$(comm -13 <(printf '%s\n' "$example_names") <(printf '%s\n' "$live_names"))"
[ -n "$missing" ] && printf '  only in config.env.example: %s\n' $missing
[ -n "$extra" ] && printf '  only in config.env:         %s\n' $extra
exit 1
