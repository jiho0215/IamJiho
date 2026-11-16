'use strict';
// The one place the ack rule lives. An ack is an issue comment whose FIRST line is
//   ack <issue#> <plan-sha>: <impact>
// It covers `hash` for plan item `id` when the plan at <plan-sha> hashes that item to exactly `hash`.
const { planHashes } = require('./plan');

const ACK_RE = /^ack (\d+) ([0-9a-f]{7,40}):/;
const cache = new Map(); // coreDir|planPath|sha -> Map or null (a sha names immutable content)

function hashesAt(coreDir, config, sha) {
  const key = [coreDir, (config && config.plan && config.plan.path) || '', sha].join('|');
  if (!cache.has(key)) {
    let m = null;
    try { m = planHashes(coreDir, sha, config); } catch { m = null; }
    cache.set(key, m);
  }
  return cache.get(key);
}

// comments: issue comment objects; ones carrying issue_url for another issue are ignored.
function ackCovers({ coreDir, config, comments, issue, id, hash }) {
  const n = Number(issue && typeof issue === 'object' ? issue.number : issue);
  for (const c of comments || []) {
    if (c.issue_url && !String(c.issue_url).endsWith(`/issues/${n}`)) continue;
    const first = String(c.body || '').replace(/\r/g, '').split('\n')[0];
    const m = ACK_RE.exec(first);
    if (!m || Number(m[1]) !== n) continue;
    const h = hashesAt(coreDir, config, m[2]);
    if (h && h.get(id) === hash) return true;
  }
  return false;
}

module.exports = { ackCovers };
