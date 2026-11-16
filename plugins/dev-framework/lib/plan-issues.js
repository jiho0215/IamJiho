'use strict';
// Shared by ticket-sync and reconcile: the plan repo's issues, found by one paginated list (never /search).

function sleepMs(ms) {
  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const labelNames = (iss) => (iss.labels || []).map((x) => (typeof x === 'string' ? x : x.name)).filter(Boolean);

// -> { byId: Map(planId -> issue; an open issue beats a closed one), planIds: [[planId, issue]] }
function readIssues(gh, planRepo) {
  const byId = new Map();
  const all = gh.paginate(`repos/${planRepo}/issues?state=all`).filter((i) => !i.pull_request);
  const planIds = [];
  for (const iss of all) {
    const l = labelNames(iss).find((n) => n.startsWith('plan:'));
    if (!l) continue;
    planIds.push([l.slice(5), iss]);
  }
  for (const [id, iss] of planIds) {
    const cur = byId.get(id);
    if (!cur || (cur.state !== 'open' && iss.state === 'open')) byId.set(id, iss);
  }
  return { byId, planIds };
}

module.exports = { readIssues, sleepMs, labelNames };
