// Reads the JSON that `claude -p --output-format json` printed ($RESULT_JSON),
// writes the run's final message to $RESULT_TXT, and prints "cost session subtype".
// A run that crashed or timed out leaves no JSON; that prints "0.00 - no-result".
// A run that could not sign in to Claude prints subtype auth-failed: the CLI then
// reports subtype "success" with is_error set, and the PR was never looked at.
const fs = require('fs');

const AUTH_FAILURE = /Failed to authenticate|Invalid API key|OAuth token (has )?(expired|revoked)|run `?claude auth login|Please run \/login/i;

let result = {};
try {
  result = JSON.parse(fs.readFileSync(process.env.RESULT_JSON, 'utf8'));
} catch (error) {
  // No result: reported as no-result below.
}
const text = typeof result.result === 'string' ? result.result : '';
fs.writeFileSync(process.env.RESULT_TXT, text);
const authFailed = result.is_error === true && AUTH_FAILURE.test(text);
console.log([
  (result.total_cost_usd || 0).toFixed(2),
  result.session_id || '-',
  authFailed ? 'auth-failed' : result.subtype || 'no-result',
].join(' '));
