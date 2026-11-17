'use strict';
// Issue-comment commands. Only line 1 of a comment is read:  <kind> <issue#>[:] <rest>
// (lib/acks.js keeps its own ack rule, which also needs the plan sha.)
const KINDS = ['ack', 'owner-ask', 'owner-said', 'plan-ready', 'stopped', 'plan-request', 'plan-applied'];
const RE = new RegExp(String.raw`^(${KINDS.join('|')})\s+#?(\d+)(?![\w-])[:\s]*(.*)$`);

function parseCommand(commentBody) {
  const first = String(commentBody || '').replace(/\r/g, '').split('\n')[0];
  const m = RE.exec(first);
  return m ? { kind: m[1], issue: Number(m[2]), rest: m[3].trim() } : null;
}

module.exports = { parseCommand, KINDS };
