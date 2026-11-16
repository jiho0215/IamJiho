'use strict';
// Pure: ticket state from facts. No git, no GitHub.
// facts: { mergedPr, openPr, branch (truthy when present),
//          cites (Map id -> hash on the issue's Cites: line), current (Map id -> hash in the plan now),
//          acked (Set of cited IDs whose current hash an ack covers), depStates (Map id -> state) }
function staleCites(facts) {
  const out = [];
  for (const [id, cited] of facts.cites || []) {
    const cur = facts.current && facts.current.get(id);
    if (cur && cur !== cited && !(facts.acked && facts.acked.has(id))) out.push({ id, cited, cur });
  }
  return out;
}

function deriveState(item, facts = {}) {
  if (facts.mergedPr) return { state: 'done', why: `PR #${facts.mergedPr.number} merged into the default branch` };
  const stale = staleCites(facts);
  if (stale.length) {
    return { state: 'needs-ack', why: `unacknowledged plan change: ${stale.map((x) => `${x.id}@${x.cited} -> ${x.cur}`).join(', ')}` };
  }
  if (facts.openPr) return { state: 'in-review', why: `PR #${facts.openPr.number} is open` };
  if (facts.branch) return { state: 'in-progress', why: `claim branch ${facts.branch} exists` };
  const open = (item.deps || []).filter((d) => (facts.depStates && facts.depStates.get(d)) !== 'done');
  if (open.length) return { state: 'blocked', why: `waiting on ${open.join(', ')}` };
  return { state: item.fields.state, why: 'plan state field' };
}

module.exports = { deriveState, staleCites };
