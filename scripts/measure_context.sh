#!/usr/bin/env bash
# Prints how many tokens a lean run carries before it does anything: the fixed
# cost re-sent with every tool call. Costs about one cent (one Sonnet reply).
#
#   measure_context.sh            expect about 10K; a normal session is about 51K

out=$(echo "Reply with the single word OK." |
  bash "$(dirname "${BASH_SOURCE[0]}")/claude_lean.sh" --model sonnet --output-format json --no-session-persistence) || exit 1
echo "$out" | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const j = JSON.parse(s), u = j.usage || {};
  const context = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
  console.log(`context ${context} tokens, reply ${JSON.stringify(j.result)}, cost $${(j.total_cost_usd || 0).toFixed(4)}`);
});'
