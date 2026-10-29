// Summarises what is new on one PR for the update watcher.
//
// Reads on stdin the raw arrays of three GitHub API calls:
//
//   {"comments": [...], "reviewComments": [...], "reviews": [...]}
//
// from gh api repos/R/issues/N/comments, repos/R/pulls/N/comments and
// repos/R/pulls/N/reviews. Reads from the environment:
//
//   SINCE   ISO time; items created or submitted at or before it are dropped.
//           Empty or unset keeps everything.
//   IGNORE  space-separated logins whose items are dropped (case-insensitive).
//
// Prints exactly two lines:
//
//   1. the newest created_at / submitted_at among the kept items, or - when
//      nothing is kept
//   2. a summary phrase, or an empty line when nothing is kept
//
// The phrase is: PARTS from LOGINS
//
//   PARTS   the parts that have a count, in this order, joined with ", " and a
//           final " and ":
//             an approval | N approvals                      (APPROVED reviews)
//             a review requesting changes | N reviews requesting changes
//                                                     (CHANGES_REQUESTED reviews)
//             1 comment | N comments       (issue comments + review comments +
//                                            COMMENTED reviews with a body)
//           DISMISSED and PENDING reviews, and COMMENTED reviews with no body,
//           are not counted.
//   LOGINS  the distinct authors of the counted items, oldest item first, in
//           the case GitHub returned, joined with ", " and a final " and ".
//
// Invalid JSON or a missing array: prints "-" and an empty line, one line on
// stderr, exit status 2.
const fs = require('fs');

const FAIL_STATUS = 2;

const fail = message => {
  process.stdout.write('-\n\n');
  process.stderr.write(`pr_updates: ${message}\n`);
  process.exit(FAIL_STATUS);
};

const loginOf = item => (item.user && item.user.login) || 'unknown';

// Normalises the three arrays to {login, at, ms, state?, body} items.
const toItems = (list, timeField, kind) => list
  .filter(item => item && typeof item === 'object')
  .map(item => ({
    kind,
    login: loginOf(item),
    at: item[timeField],
    ms: Date.parse(item[timeField]),
    state: item.state,
    body: item.body || '',
  }));

// Keeps the items newer than `since` (a time in ms, or NaN for no limit) and
// not written by an ignored login, oldest first.
const keep = (items, since, ignore) => items
  .filter(item => !Number.isNaN(item.ms))
  .filter(item => Number.isNaN(since) || item.ms > since)
  .filter(item => !ignore.has(item.login.toLowerCase()))
  .sort((a, b) => a.ms - b.ms);

// Counts approvals, change requests and comments, and collects the authors of
// the items that were counted.
const countKinds = items => {
  const counts = { approvals: 0, changes: 0, comments: 0 };
  const logins = [];
  for (const item of items) {
    let counted = true;
    if (item.kind === 'review' && item.state === 'APPROVED') counts.approvals++;
    else if (item.kind === 'review' && item.state === 'CHANGES_REQUESTED') counts.changes++;
    else if (item.kind !== 'review' || (item.state === 'COMMENTED' && item.body.trim() !== '')) counts.comments++;
    else counted = false;
    if (counted && !logins.includes(item.login)) logins.push(item.login);
  }
  return { counts, logins };
};

const joinAnd = words => (words.length < 2
  ? words.join('')
  : `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}`);

const plural = (n, one, many) => (n === 1 ? one : `${n} ${many}`);

const phrase = ({ counts, logins }) => {
  const parts = [];
  if (counts.approvals) parts.push(plural(counts.approvals, 'an approval', 'approvals'));
  if (counts.changes) parts.push(plural(counts.changes, 'a review requesting changes', 'reviews requesting changes'));
  if (counts.comments) parts.push(plural(counts.comments, '1 comment', 'comments'));
  return parts.length ? `${joinAnd(parts)} from ${joinAnd(logins)}` : '';
};

let input;
try {
  input = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (err) {
  fail(`stdin is not valid JSON: ${err.message}`);
}
for (const name of ['comments', 'reviewComments', 'reviews']) {
  if (!input || !Array.isArray(input[name])) fail(`"${name}" is missing or not an array`);
}

const sinceText = (process.env.SINCE || '').trim();
const since = sinceText ? Date.parse(sinceText) : NaN;
if (sinceText && Number.isNaN(since)) fail(`SINCE is not a time: ${sinceText}`);
const ignore = new Set((process.env.IGNORE || '').split(/\s+/).filter(Boolean).map(l => l.toLowerCase()));

const kept = keep([
  ...toItems(input.reviews, 'submitted_at', 'review'),
  ...toItems(input.reviewComments, 'created_at', 'reviewComment'),
  ...toItems(input.comments, 'created_at', 'comment'),
], since, ignore);

const newest = kept.length ? kept[kept.length - 1].at : '-';
process.stdout.write(`${newest}\n${phrase(countKinds(kept))}\n`);
