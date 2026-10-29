#!/usr/bin/env bash
# Runs scripts/send_to_session.js against a fake inbox (tests/fake_inbox.js)
# listening on a made-up pipe or socket, with a made-up CLAUDE_HOME holding the
# session's registry entry and key file. No real session is contacted.
#
# Needs only node.

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS/../scripts/send_to_session.js"

SERVER_PID=
WORK="$(mktemp -d)"
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
# node wants a path it can open; on Windows that is the mixed form (C:/...).
WORK_DIR="$(cd "$WORK" && { pwd -W 2>/dev/null || pwd; })"
SESSIONS="$WORK_DIR/home/sessions"
mkdir -p "$SESSIONS"

TOKEN=0123456789abcdef0123456789abcdef
RANDOM_HEX="$(node -e "process.stdout.write(require('crypto').randomBytes(16).toString('hex'))")"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) PIPE="\\\\.\\pipe\\LOCAL\\cc-msg-test$RANDOM_HEX" ;;
  *) PIPE="$WORK_DIR/cc-msg-test.sock" ;;
esac

# The pipe path goes through JSON.stringify so its backslashes are escaped.
write_registry() {
  node -e '
    const [dir, pipe] = process.argv.slice(1);
    require("fs").writeFileSync(dir + "/4242.json",
      JSON.stringify({ pid: 4242, sessionId: "s-1", messagingSocketPath: pipe }));
  ' "$SESSIONS" "$PIPE"
}
write_key() {
  node -e '
    const [dir, token] = process.argv.slice(1);
    require("fs").writeFileSync(dir + "/4242." + "0".repeat(64) + ".key",
      JSON.stringify({ peerToken: token }));
  ' "$SESSIONS" "$TOKEN"
}
write_registry
write_key

RECEIVED="$WORK_DIR/received.txt"
node "$TESTS/fake_inbox.js" "$PIPE" "$RECEIVED" > "$WORK/server.out" &
SERVER_PID=$!
for _ in $(seq 50); do grep -q listening "$WORK/server.out" && break; sleep 0.1; done

send() {
  CLAUDE_HOME="$WORK_DIR/home" node "$SCRIPT" "$@" 2>"$WORK/stderr"
  echo $? > "$WORK/status"
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

echo "hello there" | send 4242 s-1
check "a message to a live session is sent" "0" "$(cat "$WORK/status")"
check "nothing is written to stderr on success" "" "$(cat "$WORK/stderr")"
check "the first line is the auth frame" \
  "{\"type\":\"auth\",\"token\":\"$TOKEN\"}" "$(sed -n 1p "$RECEIVED")"
check "the second line is the message, stdin verbatim" \
  '{"type":"user","message":{"role":"user","content":"hello there\n"}}' "$(sed -n 2p "$RECEIVED")"
check "nothing else is sent" "2" "$(wc -l < "$RECEIVED" | tr -d ' ')"

echo "hello" | send 4242 s-other
check "a registry entry for another session fails" "1" "$(cat "$WORK/status")"
check "and says so" "registry entry is for another session" "$(cat "$WORK/stderr")"

echo "hello" | send 9999 s-1
check "a pid with no registry entry fails" "1" "$(cat "$WORK/status")"
check "and says so" "no registry entry for pid 9999" "$(cat "$WORK/stderr")"

send 4242 < /dev/null
check "a missing session id is a usage error" "2" "$(cat "$WORK/status")"

rm "$SESSIONS"/4242.*.key
echo "hello" | send 4242 s-1
check "a missing key file fails" "1" "$(cat "$WORK/status")"
check "and says so" "no key file for pid 4242" "$(cat "$WORK/stderr")"
write_key

kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=
# On Windows the pipe goes away when the process does, a moment later.
for _ in $(seq 50); do
  echo "hello" | send 4242 s-1
  [ "$(cat "$WORK/status")" = 1 ] && break
  sleep 0.1
done
check "a stopped server fails" "1" "$(cat "$WORK/status")"
check "with the connect error code" "1" \
  "$(grep -cE '^connect failed: (ENOENT|ECONNREFUSED)$' "$WORK/stderr")"

exit "$failed"
