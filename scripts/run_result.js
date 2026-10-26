// Reads the JSON that `claude -p --output-format json` printed ($RESULT_JSON),
// writes the run's final message to $RESULT_TXT, and prints "cost session subtype".
// A run that crashed or timed out leaves no JSON; that prints "0.00 - no-result".
const fs = require('fs');

let result = {};
try {
  result = JSON.parse(fs.readFileSync(process.env.RESULT_JSON, 'utf8'));
} catch (error) {
  // No result: reported as no-result below.
}
fs.writeFileSync(process.env.RESULT_TXT, typeof result.result === 'string' ? result.result : '');
console.log([
  (result.total_cost_usd || 0).toFixed(2),
  result.session_id || '-',
  result.subtype || 'no-result',
].join(' '));
