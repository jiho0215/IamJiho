'use strict';
// Pure: ticket state from facts. No git, no GitHub.
// facts: { mergedPr, openPr, branch (truthy when present), citedHash, currentHash,
//          ackedHashes (Set of hashes an ack covers), depStates (Map id -> state) }
function deriveState(item, facts = {}) {
  if (facts.mergedPr) return { state: 'done', why: `PR #${facts.mergedPr.number} merged into the default branch` };
  if (facts.citedHash && facts.currentHash && facts.citedHash !== facts.currentHash
      && !(facts.ackedHashes && facts.ackedHashes.has(facts.currentHash))) {
    return { state: 'needs-ack', why: `issue cites ${item.id}@${facts.citedHash}, plan is now ${facts.currentHash}, no ack` };
  }
  if (facts.openPr) return { state: 'in-review', why: `PR #${facts.openPr.number} is open` };
  if (facts.branch) return { state: 'in-progress', why: `claim branch ${facts.branch} exists` };
  const open = (item.deps || []).filter((d) => (facts.depStates && facts.depStates.get(d)) !== 'done');
  if (open.length) return { state: 'blocked', why: `waiting on ${open.join(', ')}` };
  return { state: item.fields.state, why: 'plan state field' };
}

module.exports = { deriveState };
