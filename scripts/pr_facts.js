// Reads $SCRATCH/pr.json (gh pr view --json ...) and $SCRATCH/checks.json (gh pr
// checks --json ...) for run_review.sh.
//
// Writes the free text to files in $SCRATCH: title.txt, description.md, and
// earlier-review.md / earlier-review-at.txt (my last review with a verdict, or
// my last comment-only review when there is none), and checks.md (the CI checks on
// the head: the failed and running ones in full, the rest as a count). Prints the
// plain tokens on one line:
//
//   url author state isDraft head additions deletions changedFiles
//   earlierState earlierCommit myVerdictCount
//
// $MY is the space-separated list of my logins.
const fs = require('fs');
const path = require('path');

const dir = process.env.SCRATCH;
const me = (process.env.MY || '').split(/\s+/).filter(Boolean);
const pr = JSON.parse(fs.readFileSync(path.join(dir, 'pr.json'), 'utf8'));
const write = (name, text) => fs.writeFileSync(path.join(dir, name), text);

write('title.txt', pr.title || '');
write('description.md', (pr.body || '').trim() || '(The PR has no description.)');

const mine = (pr.reviews || [])
  .filter(r => me.includes((r.author || {}).login))
  .sort((a, b) => (a.submittedAt || '').localeCompare(b.submittedAt || ''));
const verdicts = mine.filter(r => r.state !== 'COMMENTED');
const last = verdicts[verdicts.length - 1] || mine[mine.length - 1];
write('earlier-review.md', last ? last.body || '' : '');
write('earlier-review-at.txt', last ? last.submittedAt || '' : '');

// The CI checks on the head ($SCRATCH/checks.json, from gh pr checks --json), so
// the review can say whether what a failed check reports (a committed credential,
// a broken test) is real. gh pr view leaves out a status's description, which is
// where a scanner says what it found; gh pr checks has it.
const checkLines = [`# CI checks on ${(pr.headRefOid || '').slice(0, 7)}, when this run started`, ''];
let checks = [];
try {
  const raw = fs.existsSync(path.join(dir, 'checks.json'))
    ? fs.readFileSync(path.join(dir, 'checks.json'), 'utf8').trim() : '';
  checks = raw ? JSON.parse(raw) : [];
  if (!Array.isArray(checks)) throw new Error('not a list');
} catch (e) {
  checks = null;
}
if (checks === null) {
  checkLines.push('The checks could not be read; run `gh pr checks` for them.');
} else if (checks.length === 0) {
  checkLines.push('The head has no checks.');
} else {
  const failed = checks.filter(c => c.bucket === 'fail');
  const running = checks.filter(c => c.bucket === 'pending');
  const rest = checks.length - failed.length - running.length;
  const said = c => (c.description ? `: ${c.description.replace(/\.$/, '')}` : '');
  if (failed.length === 0 && running.length === 0) {
    checkLines.push(`No check failed and none is running. Passed or skipped: ${rest}.`);
  } else {
    if (failed.length) {
      checkLines.push('Failed:', ...failed.map(c => `- ${c.name}${said(c)}.${c.link ? ` Details: ${c.link}` : ''}`), '');
    }
    if (running.length) checkLines.push('Still running:', ...running.map(c => `- ${c.name}${said(c)}`), '');
    checkLines.push(`Passed or skipped: ${rest}.`);
  }
}
write('checks.md', checkLines.join('\n') + '\n');

console.log([
  pr.url, (pr.author || {}).login || 'unknown', pr.state, pr.isDraft, pr.headRefOid,
  pr.additions, pr.deletions, pr.changedFiles,
  last ? last.state : 'NONE', last && last.commit ? last.commit.oid : 'unknown',
  verdicts.length,
].join(' '));
