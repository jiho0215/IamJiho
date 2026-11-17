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

// Claim branch names (t/*) of a repo. git/matching-refs ignores page= and always returns the whole list,
// so it is ONE read, never paginate() (which would see the same full page forever).
function claimRefs(gh, repo) {
  const path = `repos/${repo}/git/matching-refs/heads/t/`;
  const rows = gh.api('GET', path);
  if (!Array.isArray(rows)) throw new Error(`expected an array from ${path}`);
  return rows.map((r) => String((r && r.ref) || '').replace(/^refs\/heads\//, ''));
}

module.exports = { readIssues, sleepMs, labelNames, claimRefs };
