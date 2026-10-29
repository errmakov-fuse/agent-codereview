// Posts one message into a live Claude Code session's inbox.
//
//   echo "message" | node send_to_session.js <pid> <session id>
//
// The message is stdin, exactly as read. $CLAUDE_HOME (default ~/.claude) holds
// sessions/<pid>.json, which names the inbox (a named pipe on Windows, a socket
// elsewhere) and the session it belongs to, and sessions/<pid>.<64 hex>.key,
// which holds the token the inbox wants first.
//
// The inbox answers nothing, and the session may hold the message until its
// owner approves it, so a clean close after writing is all the success there is.
//
// Exit 0 sent; 1 not sent (one line on stderr says why); 2 wrong arguments.
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const TIMEOUT_MS = 10000;

class SendError extends Error {}

// {json, key} for the session with this pid: its registry entry and key file
// (the newest, when there are several).
function readRegistry(home, pid) {
  const dir = path.join(home, 'sessions');
  const read = (file) => JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  let json;
  try {
    json = read(`${pid}.json`);
  } catch (e) {
    throw new SendError(`no registry entry for pid ${pid}`);
  }
  const keyFile = /^\d+\.[0-9a-f]{64}\.key$/;
  const keys = fs
    .readdirSync(dir)
    .filter((name) => keyFile.test(name) && name.startsWith(`${pid}.`))
    .map((name) => ({ name, mtime: fs.statSync(path.join(dir, name)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  if (!keys.length) throw new SendError(`no key file for pid ${pid}`);
  return { json, key: read(keys[0].name) };
}

// Resolves once the inbox has closed the connection after both lines went out.
function send(socketPath, token, content) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new SendError('timeout after 10 seconds'));
    }, TIMEOUT_MS);
    const done = (fn, value) => {
      clearTimeout(timer);
      fn(value);
    };
    socket.on('connect', () => {
      socket.write(JSON.stringify({ type: 'auth', token }) + '\n');
      socket.end(JSON.stringify({ type: 'user', message: { role: 'user', content } }) + '\n');
    });
    socket.on('error', (e) => done(reject, new SendError(`connect failed: ${e.code || e.message}`)));
    socket.on('close', (hadError) => hadError || done(resolve));
    socket.resume();
  });
}

function readStdin() {
  return fs.readFileSync(0, 'utf8');
}

async function main() {
  const [pid, sessionId] = process.argv.slice(2);
  if (!/^\d+$/.test(pid || '') || !sessionId) {
    console.error('usage: send_to_session.js <pid> <session id>  (message on stdin)');
    return 2;
  }
  try {
    const home = process.env.CLAUDE_HOME || path.join(os.homedir(), '.claude');
    const { json, key } = readRegistry(home, pid);
    if (json.sessionId !== sessionId) throw new SendError('registry entry is for another session');
    if (!json.messagingSocketPath || !key.peerToken) throw new SendError(`no inbox for pid ${pid}`);
    await send(json.messagingSocketPath, key.peerToken, readStdin());
    return 0;
  } catch (e) {
    console.error(e instanceof SendError ? e.message : `failed: ${e.message}`);
    return 1;
  }
}

main().then((code) => process.exit(code));
