// Maps Claude Code sessions to the PRs they own, for the PR update watcher.
//
// Reads the JSON array printed by `claude agents --json --all` on stdin. Env:
// CLAUDE_HOME (default ~/.claude) and STATE_DIR (where scan.tsv lives).
// Prints tab-separated lines:
//
//   SESSION  short-id  session-id  live|retired  pid|-  startedAt-ms  cwd  name
//   PR       owner/repo  number  session-id  created|linked|mentioned
//
// A session is live when it has a pid, and retired when it is a background
// session with no pid whose jobs/<id>/state.json still exists; any other session
// is skipped. Its transcript is the linkScanPath in that state.json, or else
// projects/<cwd with non-alphanumerics as "-">/<session id>.jsonl.
//
// A PR has three sources, best first, and is printed once per session with the
// best one found in this run:
//   created    a tool result that is just the URL `gh pr create` prints: at most
//              three lines, the last one exactly a PR URL
//   linked     a pr-link record; Claude Code writes one whenever a PR URL goes by
//              in tool output, so it means "seen", not "created"
//   mentioned  a PR URL in something the user typed (a string-content user turn)
//
// scan.tsv (session id, bytes) remembers how far each transcript has been read,
// so only new lines are looked at. A last line with no newline yet is left for
// the next run, and a file that shrank is read again from the start.
const fs = require('fs');
const os = require('os');
const path = require('path');

const PULL_URL = /github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/g;
const CREATED_URL = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)$/;
const MAX_CREATE_LINES = 3;
const SOURCE_RANK = { created: 0, linked: 1, mentioned: 2 };
const NEWLINE = 0x0a;
const BOM = String.fromCharCode(0xfeff); // Windows PowerShell 5.1 puts one on piped text

const claudeHome = process.env.CLAUDE_HOME || path.join(os.homedir(), '.claude');
const stateDir = process.env.STATE_DIR;

const oneLine = text => String(text).replace(/[\t\r\n]+/g, ' ');
const jobStatePath = (session, home) => path.join(home, 'jobs', session.id, 'state.json');

const isSession = s => Boolean(s) && typeof s === 'object' && typeof s.id === 'string' && typeof s.sessionId === 'string';

function classify(session, home) {
  if (typeof session.pid === 'number') return 'live';
  if (session.kind === 'background' && fs.existsSync(jobStatePath(session, home))) return 'retired';
  return null;
}

function transcriptPath(session, home) {
  try {
    const state = JSON.parse(fs.readFileSync(jobStatePath(session, home), 'utf8'));
    if (state && typeof state.linkScanPath === 'string' && state.linkScanPath) return state.linkScanPath;
  } catch (e) {
    // A missing job state is normal (an interactive session); anything else is
    // worth a note. Either way the transcript is found by its slug.
    if (e.code !== 'ENOENT') console.error(`session_prs: ${session.id}: unreadable job state, using the project path: ${e.message}`);
  }
  const slug = String(session.cwd || '').replace(/[^A-Za-z0-9]/g, '-');
  return path.join(home, 'projects', slug, `${session.sessionId}.jsonl`);
}

// The text of a tool_result block: a string, or an array of {type:"text", text}.
function toolResultText(block) {
  if (typeof block.content === 'string') return block.content;
  if (!Array.isArray(block.content)) return '';
  return block.content.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('\n');
}

// What `gh pr create` prints: at most a few lines ending in the PR URL.
function createdBy(blocks) {
  const found = [];
  for (const block of blocks) {
    if (!block || block.type !== 'tool_result') continue;
    const lines = toolResultText(block).trim().split(/\r?\n/);
    const m = lines.length <= MAX_CREATE_LINES ? CREATED_URL.exec(lines[lines.length - 1].trim()) : null;
    if (m) found.push({ repo: m[1], number: Number(m[2]), source: 'created' });
  }
  return found;
}

// Returns [{repo, number, source}] for one transcript line.
function prsInLine(line) {
  if (!line.includes('"pr-link"') && !line.includes('/pull/')) return [];
  let entry;
  try {
    entry = JSON.parse(line);
  } catch (e) {
    return [];
  }
  if (entry.type === 'pr-link' && entry.prRepository && Number.isInteger(entry.prNumber)) {
    return [{ repo: entry.prRepository, number: entry.prNumber, source: 'linked' }];
  }
  const content = entry.type === 'user' && entry.message ? entry.message.content : null;
  if (Array.isArray(content)) return createdBy(content);
  if (typeof content !== 'string') return [];
  return [...content.matchAll(PULL_URL)].map(m => ({ repo: m[1], number: Number(m[2]), source: 'mentioned' }));
}

// One entry per PR, keeping the best source seen: created, then linked, then mentioned.
function bestSources(rows) {
  const best = new Map();
  for (const { repo, number, source } of rows) {
    const key = `${repo}\t${number}`;
    if (!best.has(key) || SOURCE_RANK[source] < SOURCE_RANK[best.get(key)]) best.set(key, source);
  }
  return best;
}

// Reads the transcript from `offset` and returns {rows, bytes}: the PRs found
// and the offset to resume from, which stops short of an unfinished last line.
function scanTranscript(file, offset) {
  const start = fs.statSync(file).size < offset ? 0 : offset;
  return new Promise((resolve, reject) => {
    const rows = [];
    let bytes = start;
    let pending = [];
    const stream = fs.createReadStream(file, { start });
    stream.on('error', reject);
    stream.on('data', chunk => {
      const end = chunk.lastIndexOf(NEWLINE);
      if (end === -1) {
        pending.push(chunk);
        return;
      }
      const complete = Buffer.concat([...pending, chunk.subarray(0, end + 1)]);
      pending = [chunk.subarray(end + 1)];
      bytes += complete.length;
      for (const line of complete.toString('utf8').split('\n')) rows.push(...prsInLine(line));
    });
    stream.on('end', () => resolve({ rows, bytes }));
  });
}

function readScan(file) {
  const offsets = new Map();
  if (!fs.existsSync(file)) return offsets;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const [id, bytes] = line.split('\t');
    if (id && /^\d+$/.test(bytes)) offsets.set(id, Number(bytes));
  }
  return offsets;
}

function writeScan(file, offsets) {
  const text = [...offsets].map(([id, bytes]) => `${id}\t${bytes}\n`).join('');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(`${file}.tmp`, text);
  fs.renameSync(`${file}.tmp`, file);
}

function sessionLine(session, status) {
  const fields = ['SESSION', session.id, session.sessionId, status,
    typeof session.pid === 'number' ? session.pid : '-', session.startedAt, session.cwd, session.name || '-'];
  return fields.map(oneLine).join('\t');
}

async function main() {
  if (!stateDir) throw new Error('STATE_DIR is not set');
  const input = fs.readFileSync(0, 'utf8');
  const sessions = JSON.parse(input.startsWith(BOM) ? input.slice(1) : input);
  if (!Array.isArray(sessions)) throw new Error('stdin is not the array from `claude agents --json --all`');
  const scanFile = path.join(stateDir, 'scan.tsv');
  const offsets = readScan(scanFile);

  for (const session of sessions) {
    if (!isSession(session)) {
      console.error(`session_prs: skipping an entry without a string id and sessionId: ${JSON.stringify(session)}`);
      continue;
    }
    const status = classify(session, claudeHome);
    if (!status) continue;
    console.log(sessionLine(session, status));
    let scan;
    try {
      scan = await scanTranscript(transcriptPath(session, claudeHome), offsets.get(session.sessionId) || 0);
    } catch (e) {
      console.error(`session_prs: ${session.id}: cannot read transcript: ${e.message}`);
      continue;
    }
    offsets.set(session.sessionId, scan.bytes);
    for (const [key, source] of bestSources(scan.rows)) {
      console.log(['PR', key, session.sessionId, source].join('\t'));
    }
  }
  writeScan(scanFile, offsets);
}

main().catch(e => {
  console.error(`session_prs: ${e.message}`);
  process.exit(1);
});
