// A stand-in for a Claude Code session's inbox, for tests/send_to_session.sh.
//
//   node fake_inbox.js <socket or pipe path> <file>
//
// Listens on the path, appends every received line to <file>, and closes the
// connection once it has seen two lines (auth, then the message).
const net = require('net');
const fs = require('fs');

const [socketPath, outFile] = process.argv.slice(2);
const server = net.createServer((conn) => {
  let buffered = '';
  let lines = 0;
  conn.setEncoding('utf8');
  conn.on('error', () => {});
  conn.on('data', (chunk) => {
    buffered += chunk;
    let at;
    while ((at = buffered.indexOf('\n')) >= 0) {
      fs.appendFileSync(outFile, buffered.slice(0, at) + '\n');
      buffered = buffered.slice(at + 1);
      if (++lines === 2) conn.end();
    }
  });
});
server.listen(socketPath, () => console.log('listening'));
