'use strict';
// Pure: ticket state from facts. No git, no GitHub.
// facts: { mergedPr, openPr, branch (truthy when present),
//          cites (Map id -> hash on the issue's Cites: line), current (Map id -> hash in the plan now),
//          expected (IDs the issue must cite: the item and its decisions),
//          acked (Set of cited IDs whose current hash an ack covers), depStates (Map id -> state) }
// Each entry is one reason for needs-ack:
//   { id, cited, cur }                 the cited hash is not the plan's and no ack covers the current one
//   { id, cited, cur: null, removed }  the cited ID is no longer in the plan (the merge gate refuses it too); no ack
//                                      can cover it - the ticket must be re-cited
//   { id, cited: null, cur, missing }  an expected ID is absent from the Cites line (deleted on GitHub); only
//                                      ticket-sync --refresh-cites gives it a hash again
function staleCites(facts) {
  const out = [];
  if (!facts.cites || !facts.current) return out;
  for (const [id, cited] of facts.cites) {
    const cur = facts.current.get(id);
    if (!cur) out.push({ id, cited, cur: null, removed: true });
    else if (cur !== cited && !(facts.acked && facts.acked.has(id))) out.push({ id, cited, cur });
  }
  for (const id of facts.expected || []) {
    if (!facts.cites.has(id)) out.push({ id, cited: null, cur: facts.current.get(id) || null, missing: true });
  }
  return out;
}

function staleWhy(stale) {
  const changed = stale.filter((x) => !x.removed && !x.missing);
  return [
    ...(changed.length ? [`unacknowledged plan change: ${changed.map((x) => `${x.id}@${x.cited} -> ${x.cur}`).join(', ')}`] : []),
    ...stale.filter((x) => x.removed).map((x) => `${x.id} removed from plan`),
    ...stale.filter((x) => x.missing).map((x) => `${x.id} missing from Cites (run ticket-sync --refresh-cites)`),
  ].join('; ');
}

function deriveState(item, facts = {}) {
  if (facts.mergedPr) return { state: 'done', why: `PR #${facts.mergedPr.number} merged into the default branch` };
  const stale = staleCites(facts);
  if (stale.length) return { state: 'needs-ack', why: staleWhy(stale) };
  if (facts.openPr) return { state: 'in-review', why: `PR #${facts.openPr.number} is open` };
  if (facts.branch) return { state: 'in-progress', why: `claim branch ${facts.branch} exists` };
  const open = (item.deps || []).filter((d) => (facts.depStates && facts.depStates.get(d)) !== 'done');
  if (open.length) return { state: 'blocked', why: `waiting on ${open.join(', ')}` };
  return { state: item.fields.state, why: 'plan state field' };
}

module.exports = { deriveState, staleCites };
