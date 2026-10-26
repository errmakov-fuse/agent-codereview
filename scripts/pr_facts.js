// Reads $SCRATCH/pr.json (gh pr view --json ...) for run_review.sh.
//
// Writes the free text to files in $SCRATCH: title.txt, description.md, and
// earlier-review.md / earlier-review-at.txt (my last review with a verdict, or
// my last comment-only review when there is none). Prints the plain tokens on
// one line:
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

console.log([
  pr.url, (pr.author || {}).login || 'unknown', pr.state, pr.isDraft, pr.headRefOid,
  pr.additions, pr.deletions, pr.changedFiles,
  last ? last.state : 'NONE', last && last.commit ? last.commit.oid : 'unknown',
  verdicts.length,
].join(' '));
