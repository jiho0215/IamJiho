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

// Who may ack: a comment counts (an ack, an owner-said, the impact marker) only when GitHub reports its author as
// OWNER, MEMBER or COLLABORATOR, or its login is in config.github.trustedAuthors. Anyone can comment on a public
// issue, so an untrusted comment is ignored, never obeyed. lib/waiting.js and lib/impact.js use this same rule.
const TRUSTED_ASSOCIATIONS = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);

function isTrustedAuthor(comment, config) {
  if (!comment) return false;
  if (TRUSTED_ASSOCIATIONS.has(comment.author_association)) return true;
  const login = String((comment.user && comment.user.login) || '').toLowerCase();
  const extra = (config && config.github && Array.isArray(config.github.trustedAuthors)) ? config.github.trustedAuthors : [];
  return login !== '' && extra.some((x) => String(x).toLowerCase() === login);
}

// comments: issue comment objects; ones carrying issue_url for another issue, or by an untrusted author, are ignored.
function ackCovers({ coreDir, config, comments, issue, id, hash }) {
  const n = Number(issue && typeof issue === 'object' ? issue.number : issue);
  for (const c of comments || []) {
    if (c.issue_url && !String(c.issue_url).endsWith(`/issues/${n}`)) continue;
    if (!isTrustedAuthor(c, config)) continue;
    const first = String(c.body || '').replace(/\r/g, '').split('\n')[0];
    const m = ACK_RE.exec(first);
    if (!m || Number(m[1]) !== n) continue;
    const h = hashesAt(coreDir, config, m[2]);
    if (h && h.get(id) === hash) return true;
  }
  return false;
}

module.exports = { ackCovers, isTrustedAuthor, TRUSTED_ASSOCIATIONS };
